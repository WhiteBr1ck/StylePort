import AVFoundation
import Foundation
import ImageIO
@preconcurrency import Photos
import os
import UIKit

nonisolated enum LivePhotoError: LocalizedError {
    case missingVideo
    case invalidPair
    case identifierChanged
    case savedAsStill

    var errorDescription: String? {
        switch self {
        case .missingVideo:
            "Live Photo 配套视频缺失，未保存静态副本。请从过片内导入原片。 / Live Photo video is missing. Import the original in GuoPian."
        case .invalidPair: "Live Photo 照片与视频无法配对，原片已保留。 / Invalid Live Photo pair; the original is retained."
        case .identifierChanged: "Live Photo 配对标识发生变化，已停止保存。 / Live Photo identifier changed; saving stopped."
        case .savedAsStill: "无法确认副本仍为 Live Photo，原片未删除。 / The copy could not be verified as Live Photo; the original was not deleted."
        }
    }
}

/// Export the complete source pair. A full-size edited photo must use its full-size movie,
/// never an unrelated original movie; otherwise fall back to the complete original pair.
nonisolated enum LivePhotoResources {
    static func resourceIndices(types: [PHAssetResourceType], requiresVideo: Bool) throws
        -> (photo: Int, video: Int?)
    {
        if !requiresVideo {
            guard let photo = types.firstIndex(of: .fullSizePhoto) ?? types.firstIndex(of: .photo)
            else { throw LivePhotoError.invalidPair }
            return (photo, nil)
        }
        if let photo = types.firstIndex(of: .fullSizePhoto),
           let video = types.firstIndex(of: .fullSizePairedVideo) { return (photo, video) }
        if let photo = types.firstIndex(of: .photo),
           let video = types.firstIndex(of: .pairedVideo) { return (photo, video) }
        throw LivePhotoError.missingVideo
    }

    static func export(_ resources: [PHAssetResource], requiresVideo: Bool) async throws
        -> ExternalPhotoInput
    {
        let indices = try resourceIndices(types: resources.map(\.type), requiresVideo: requiresVideo)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuoPian-Resources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let photo = resources[indices.photo]
        let photoURL = try await write(photo, directory: directory)
        let videoURL: URL?
        if let video = indices.video {
            videoURL = try await write(resources[video], directory: directory)
        } else { videoURL = nil }
        return ExternalPhotoInput(url: photoURL, originalFilename: photoURL.lastPathComponent,
                                  pairedVideoURL: videoURL)
    }

    private static func write(_ resource: PHAssetResource, directory: URL) async throws -> URL {
        let filename: String
        if #available(iOS 27.0, *) { filename = resource.filename ?? resource.originalFilename }
        else { filename = resource.originalFilename }
        let destination = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return destination
    }

    @MainActor
    static func providerInput(_ provider: NSItemProvider) async throws -> ExternalPhotoInput? {
        guard provider.canLoadObject(ofClass: PHLivePhoto.self) else { return nil }
        let livePhoto: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else if let photo = object as? PHLivePhoto { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: LivePhotoError.missingVideo) }
            }
        }
        return try await export(PHAssetResource.assetResources(for: livePhoto), requiresVideo: true)
    }

    static func photoIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              let identifier = maker["17"] as? String, !identifier.isEmpty else { return nil }
        return identifier
    }

    static func requireMatchingIdentifiers(photo: String?, video: String?) throws {
        guard let photo, let video, !photo.isEmpty, photo == video else { throw LivePhotoError.invalidPair }
    }

    static func validate(photoURL: URL, videoURL: URL?) async throws {
        let photoID = photoIdentifier(at: photoURL)
        guard let videoURL else {
            if photoID != nil { throw LivePhotoError.missingVideo }
            return
        }
        let metadata = try await AVURLAsset(url: videoURL).load(.metadata)
        let identifiers = AVMetadataItem.metadataItems(from: metadata,
            filteredByIdentifier: .quickTimeMetadataContentIdentifier)
        let videoID = try await identifiers.first?.load(.stringValue)
        try requireMatchingIdentifiers(photo: photoID, video: videoID)
        // Matching identifiers alone are insufficient: Photos also checks the timed still-image marker.
        let valid = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: continuation)
            PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL], placeholderImage: nil,
                                targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFit) { livePhoto, info in
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                let final = pending.withLock { value in
                    let final = value
                    value = nil
                    return final
                }
                final?.resume(returning: livePhoto != nil && info[PHLivePhotoInfoErrorKey] == nil)
            }
        }
        guard valid else { throw LivePhotoError.invalidPair }
    }
}
