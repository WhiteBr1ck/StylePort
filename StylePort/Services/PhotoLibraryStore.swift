@preconcurrency import Photos
import Foundation
import Observation

@MainActor
@Observable
final class PhotoLibraryStore: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var photos: [LibraryPhoto] = []
    private(set) var albums: [PhotoAlbum] = []
    private(set) var eligibility: [String: PhotoEligibility] = [:]
    private(set) var analysisProgress: (current: Int, total: Int)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var canReadLibrary: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestAccessAndLoad() async {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authorizationStatus = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        guard canReadLibrary else { return }
        reload()
    }

    func reload() {
        guard canReadLibrary else { return }
        photos = Self.fetchPhotos()
        albums = Self.fetchAlbums()
    }

    func photos(in albumIdentifier: String) -> [LibraryPhoto] {
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier],
            options: nil
        ).firstObject else { return [] }
        return Self.libraryPhotos(from: PHAsset.fetchAssets(in: album, options: Self.fetchOptions()))
    }

    func analyze(_ photoIdentifiers: [String]) async {
        let identifiers = photoIdentifiers.filter { eligibility[$0] == nil }
        guard !identifiers.isEmpty else { return }
        analysisProgress = (0, identifiers.count)

        for (offset, identifier) in identifiers.enumerated() {
            if Task.isCancelled { break }
            do {
                let source = try await PhotoAssetSource.load(identifier: identifier)
                eligibility[identifier] = try await PhotoConversionService.eligibility(of: source.url)
            } catch {
                eligibility[identifier] = .incompatible
            }
            analysisProgress = (offset + 1, identifiers.count)
        }
        analysisProgress = nil
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.reload()
        }
    }

    private static func fetchPhotos() -> [LibraryPhoto] {
        libraryPhotos(from: PHAsset.fetchAssets(with: .image, options: fetchOptions()))
    }

    private static func fetchAlbums() -> [PhotoAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        var results: [PhotoAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            guard collection.canPerform(.addContent) else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: fetchOptions())
            let cover = assets.firstObject?.localIdentifier
            results.append(PhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album",
                count: assets.count,
                coverAssetIdentifier: cover
            ))
        }
        return results.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    private static func libraryPhotos(from assets: PHFetchResult<PHAsset>) -> [LibraryPhoto] {
        var results: [LibraryPhoto] = []
        results.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            results.append(LibraryPhoto(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        return results
    }
}

nonisolated struct PhotoAssetSource: Sendable {
    let url: URL
    let originalFilename: String
    let assetIdentifier: String

    static func load(identifier: String) async throws -> PhotoAssetSource {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoImportError.unavailable
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
        else { throw PhotoImportError.unavailable }

        let filename: String
        if #available(iOS 27.0, *) {
            filename = resource.filename ?? resource.originalFilename
        } else {
            filename = resource.originalFilename
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuoPian-Imports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return PhotoAssetSource(
            url: destination,
            originalFilename: filename,
            assetIdentifier: identifier
        )
    }
}
