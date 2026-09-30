import CoreGraphics
import Foundation
import ImageIO
import Observation
@preconcurrency import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class PhotoImportSession {
  var pickerItems: [PhotosPickerItem] = []
  private(set) var photos: [SelectedPhoto] = []
  private(set) var loadingProgress: (current: Int, total: Int)?
  private(set) var skipped = 0
  private(set) var failures: [String] = []
  @ObservationIgnored private var importTask: Task<Void, Never>?

  init() {
    #if DEBUG
      // UI tests can exercise result presentation without relying on the system picker service.
      if ProcessInfo.processInfo.arguments.contains("--ui-test-three-imports"),
        let png = Data(
          base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ),
        let preview = UIImage(data: png)
      {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          for index in 1...3 {
            let url = directory.appendingPathComponent("Fixture\(index).png")
            try png.write(to: url)
            photos.append(
              SelectedPhoto(
                sourceURL: url, assetIdentifier: nil, preview: preview,
                pixelSize: CGSize(width: 1, height: 1), fileName: url.lastPathComponent))
          }
        } catch {
          failures = [error.localizedDescription]
        }
      }
    #endif
  }

  var hasSelection: Bool { !photos.isEmpty || skipped > 0 || !failures.isEmpty }

  func importSelection() {
    guard !pickerItems.isEmpty, importTask == nil else { return }
    let items = pickerItems
    loadingProgress = (0, items.count)
    importTask = Task {
      var imported: [SelectedPhoto] = []
      var skippedCount = 0
      var errors: [String] = []
      for (offset, item) in items.enumerated() {
        guard !Task.isCancelled else { return }
        loadingProgress = (offset + 1, items.count)
        do {
          imported.append(try await PhotoImporter.load(item))
        } catch PhotoImportError.unsupported {
          skippedCount += 1
        } catch is CancellationError {
          return
        } catch {
          errors.append(error.localizedDescription)
        }
      }
      guard !Task.isCancelled else { return }
      photos = imported
      skipped = skippedCount
      failures = errors
      loadingProgress = nil
      importTask = nil
    }
  }

  func clear() {
    guard loadingProgress == nil else { return }
    photos.removeAll()
    pickerItems.removeAll()
    skipped = 0
    failures.removeAll()
  }
}

nonisolated enum PhotoImportError: LocalizedError {
  case unavailable
  case unsupported
  case previewFailed

  var errorDescription: String? {
    switch self {
    case .unavailable: "The selected photo could not be loaded."
    case .unsupported: "This photo format is not supported."
    case .previewFailed: "A preview could not be created."
    }
  }
}

nonisolated struct PhotoImporter {
  @MainActor
  static func loadNamedPhoto(_ result: PHPickerResult) async throws -> SelectedPhoto {
    if let identifier = result.assetIdentifier,
      PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject != nil
    {
      let source = try await PhotoAssetSource.load(identifier: identifier)
      return try await readNamedFile(
        ExternalPhotoInput(url: source.url, originalFilename: source.originalFilename),
        assetIdentifier: identifier)
    }
    let input = try await namedInput(provider: result.itemProvider)
    return try await readNamedFile(input, assetIdentifier: result.assetIdentifier)
  }

  @MainActor
  static func namedInput(provider: NSItemProvider) async throws -> ExternalPhotoInput {
    guard
      let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      })
    else { throw PhotoImportError.unsupported }
    let suggestedName = provider.suggestedName
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let url else {
          continuation.resume(throwing: PhotoImportError.unavailable)
          return
        }
        do {
          let filename = resolvedFilename(
            suggestedName: suggestedName, transferredFilename: url.lastPathComponent,
            typeIdentifier: identifier)
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuoPian-Inspection", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          let destination = directory.appendingPathComponent(filename)
          // Provider URLs are valid only for the duration of this callback.
          try FileManager.default.copyItem(at: url, to: destination)
          continuation.resume(
            returning: ExternalPhotoInput(url: destination, originalFilename: filename))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  static func resolvedFilename(
    suggestedName: String?, transferredFilename: String, typeIdentifier: String
  ) -> String {
    let candidate: String
    if let suggestedName, !suggestedName.isEmpty {
      candidate = suggestedName
    } else {
      candidate = transferredFilename
    }
    let safeName = URL(fileURLWithPath: candidate).lastPathComponent
    guard !safeName.isEmpty, safeName != ".", safeName != ".." else { return "Unnamed" }
    if !URL(fileURLWithPath: safeName).pathExtension.isEmpty { return safeName }
    guard let ext = UTType(typeIdentifier)?.preferredFilenameExtension else { return safeName }
    return "\(safeName).\(ext)"
  }

  @concurrent
  static func readNamedFile(_ input: ExternalPhotoInput, assetIdentifier: String?) async throws
    -> SelectedPhoto
  {
    try Task.checkCancellation()
    let data = try Data(contentsOf: input.url, options: .mappedIfSafe)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let identifier = CGImageSourceGetType(source),
      let type = UTType(identifier as String)
    else { throw PhotoImportError.unsupported }
    return try decodedPhoto(
      data: data, contentType: type,
      source: PhotoAssetSource(
        url: input.url, originalFilename: input.originalFilename,
        assetIdentifier: assetIdentifier ?? ""),
      assetIdentifier: assetIdentifier)
  }

  @concurrent
  static func load(_ item: PhotosPickerItem) async throws -> SelectedPhoto {
    let source: PhotoAssetSource?
    if let identifier = item.itemIdentifier,
      PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject != nil
    {
      source = try await PhotoAssetSource.load(identifier: identifier)
    } else {
      source = nil
    }
    let data: Data
    if let source {
      data = try Data(contentsOf: source.url, options: .mappedIfSafe)
    } else {
      guard let imported = try await item.loadTransferable(type: Data.self), !imported.isEmpty
      else {
        throw PhotoImportError.unavailable
      }
      data = imported
    }

    let contentType = item.supportedContentTypes.first(where: {
      $0.conforms(to: .image)
    })
    guard let contentType else { throw PhotoImportError.unsupported }

    return try decodedPhoto(
      data: data, contentType: contentType, source: source, assetIdentifier: item.itemIdentifier)
  }

  private static func decodedPhoto(
    data: Data, contentType: UTType, source: PhotoAssetSource?, assetIdentifier: String?
  ) throws -> SelectedPhoto {
    let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
    guard let imageSource,
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
    else {
      throw PhotoImportError.previewFailed
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 800,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
    else {
      throw PhotoImportError.previewFailed
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("StylePort-Imports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ext = contentType.preferredFilenameExtension ?? "heic"
    let fileName = source?.originalFilename ?? "Photo.\(ext)"
    let importDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
    let url = source?.url ?? importDirectory.appendingPathComponent(fileName)
    if source == nil { try data.write(to: url, options: .atomic) }

    return SelectedPhoto(
      sourceURL: url,
      assetIdentifier: assetIdentifier,
      preview: UIImage(cgImage: thumbnail),
      pixelSize: CGSize(width: width, height: height),
      fileName: fileName
    )
  }
}
