@preconcurrency import Photos
import Foundation
import os

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
        albumIdentifier: String? = nil,
        pairedVideoURL: URL? = nil
    ) async throws -> ConvertedPhoto {
        let outputVideoURL: URL?
        if let pairedVideoURL {
            outputVideoURL = try await LivePhotoMovieConverter.convert(videoURL: pairedVideoURL, photoURL: outputURL)
        } else { outputVideoURL = nil }
        try await LivePhotoResources.validate(photoURL: outputURL, videoURL: outputVideoURL)
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
            if asset.mediaSubtypes.contains(.photoLive), pairedVideoURL == nil {
                throw LivePhotoError.missingVideo
            }
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

        let createdIdentifier = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = outputFilename ?? outputURL.lastPathComponent
                request.addResource(with: .photo, fileURL: outputURL, options: options)
                if let outputVideoURL {
                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.shouldMoveFile = false
                    videoOptions.originalFilename = URL(fileURLWithPath: options.originalFilename ?? outputURL.lastPathComponent)
                        .deletingPathExtension().lastPathComponent + ".MOV"
                    request.addResource(with: .pairedVideo, fileURL: outputVideoURL, options: videoOptions)
                }
                createdIdentifier.withLock { $0 = request.placeholderForCreatedAsset?.localIdentifier }

                if let targetAlbum,
                   let placeholder = request.placeholderForCreatedAsset,
                   let albumRequest = PHAssetCollectionChangeRequest(for: targetAlbum)
                {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoLibraryError.saveFailed)
                }
            }
        }
        guard let identifier = createdIdentifier.withLock({ $0 }),
              let created = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else { throw PhotoLibraryError.saveFailed }
        if pairedVideoURL != nil {
            guard created.mediaSubtypes.contains(.photoLive),
                  PHAssetResource.assetResources(for: created).contains(where: { $0.type == .pairedVideo })
            else { throw LivePhotoError.savedAsStill }
        }
        // Replacement is a separate transaction, only after the newly saved asset is verified.
        if let originalAsset {
            try Task.checkCancellation()
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([originalAsset] as NSArray)
            }
        }
        return ConvertedPhoto(
            outputURL: outputURL,
            replacedOriginal: replacingOriginal,
            filename: outputFilename ?? outputURL.lastPathComponent,
            savedAssetIdentifier: identifier
        )
    }
}
