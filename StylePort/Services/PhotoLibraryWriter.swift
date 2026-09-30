@preconcurrency import Photos
import Foundation

enum PhotoLibraryError: LocalizedError {
    case accessDenied
    case saveFailed
    case originalUnavailable
    case albumUnavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied: "Photo library access was not granted."
        case .saveFailed: "The converted photo could not be saved."
        case .originalUnavailable: "The original photo could not be replaced."
        case .albumUnavailable: "The destination album is no longer available."
        }
    }
}

nonisolated enum PhotoLibraryWriter {
    static func save(
        outputURL: URL,
        outputFilename: String? = nil,
        replacingOriginal: Bool,
        assetIdentifier: String?,
        albumIdentifier: String? = nil
    ) async throws -> ConvertedPhoto {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.accessDenied
        }
        let originalAsset: PHAsset?
        if replacingOriginal {
            guard let assetIdentifier,
                  let asset = PHAsset.fetchAssets(
                      withLocalIdentifiers: [assetIdentifier],
                      options: nil
                  ).firstObject
            else { throw PhotoLibraryError.originalUnavailable }
            originalAsset = asset
        } else {
            originalAsset = nil
        }

        let targetAlbum: PHAssetCollection?
        if let albumIdentifier {
            guard let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumIdentifier],
                options: nil
            ).firstObject,
                  album.canPerform(.addContent)
            else { throw PhotoLibraryError.albumUnavailable }
            targetAlbum = album
        } else {
            targetAlbum = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = outputFilename ?? outputURL.lastPathComponent
                request.addResource(with: .photo, fileURL: outputURL, options: options)

                if let targetAlbum,
                   let placeholder = request.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: targetAlbum)
                {
                    albumRequest.addAssets([placeholder] as NSArray)
                }

                if let originalAsset {
                    PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryError.saveFailed)
                }
            }
        }
        return ConvertedPhoto(
            outputURL: outputURL,
            replacedOriginal: replacingOriginal,
            filename: outputFilename ?? outputURL.lastPathComponent
        )
    }
}
