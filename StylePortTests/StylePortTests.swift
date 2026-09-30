import Foundation
import Testing
import UIKit
import PhotosUI
import SwiftUI
import AppIntents
@testable import StylePort

@Suite("StylePort basics")
struct StylePortTests {
    @Test("Inspection preserves the filename supplied by the photo picker")
    @MainActor
    func namedPhotoProvider() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("TemporaryProvider.png")
        try png.write(to: originalURL)
        let provider = NSItemProvider()
        provider.suggestedName = "IMG_8952_GP.PNG"
        provider.registerFileRepresentation(forTypeIdentifier: "public.png", fileOptions: [], visibility: .all) { completion in
            completion(originalURL, false, nil)
            return nil
        }
        let input = try await PhotoImporter.namedInput(provider: provider)
        #expect(input.originalFilename == "IMG_8952_GP.PNG")
        #expect(input.url.lastPathComponent == "IMG_8952_GP.PNG")
        #expect(try Data(contentsOf: input.url) == png)
        let photo = try await PhotoImporter.readNamedFile(input, assetIdentifier: nil)
        #expect(photo.fileName == "IMG_8952_GP.PNG")
        let metadata = try await PhotoMetadataReader.read(url: photo.sourceURL, filename: photo.fileName)
        #expect(metadata.filename == "IMG_8952_GP.PNG")
    }

    @Test("Picker filenames retain their stem, extension and case")
    func originalFilenameResolution() {
        #expect(PhotoImporter.resolvedFilename(suggestedName: "IMG_8952.HEIC", transferredFilename: "Photo.heic", typeIdentifier: "public.heic") == "IMG_8952.HEIC")
        #expect(PhotoImporter.resolvedFilename(suggestedName: "IMG_8952", transferredFilename: "Photo.heic", typeIdentifier: "public.heic") == "IMG_8952.heic")
        #expect(PhotoImporter.resolvedFilename(suggestedName: nil, transferredFilename: "IMG_0001.HEIC", typeIdentifier: "public.heic") == "IMG_0001.HEIC")
        #expect(PhotoImporter.resolvedFilename(suggestedName: "folder/IMG_8952_GP.HEIC", transferredFilename: "Photo.heic", typeIdentifier: "public.heic") == "IMG_8952_GP.HEIC")
    }

    @Test("Inspector reads PNG metadata without inventing photographic styles")
    func inspectPNG() throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let metadata = try PhotoMetadataReader.read(data: png, filename: "Photo.png")
        #expect(metadata.format == "PNG")
        #expect(metadata.byteCount == png.count)
        #expect(metadata.basics.contains { $0.id == "dimensions" && $0.value == "1 × 1 px" })
        #expect(metadata.style == nil)
        #expect(!metadata.rawFields.contains { $0.value.contains("Optional(") })
        #expect(metadata.differences(from: metadata).isEmpty)
    }

    @Test("Inspector rejects corrupt image data")
    func inspectInvalid() {
        #expect(throws: (any Error).self) {
            try PhotoMetadataReader.read(data: Data("invalid".utf8), filename: "Photo.HEIC")
        }
    }

    @Test("Photo comparison exposes added, removed and changed values")
    func metadataDifferences() {
        let original = PhotoMetadata(filename: "A", byteCount: 1, format: "HEIC", basics: [],
                                     rawFields: [.init(id: "retained", value: "yes"), .init(id: "removed", value: "old"), .init(id: "changed", value: "before")], style: nil)
        let copy = PhotoMetadata(filename: "B", byteCount: 2, format: "HEIC", basics: [],
                                 rawFields: [.init(id: "retained", value: "yes"), .init(id: "added", value: "new"), .init(id: "changed", value: "after")], style: nil)
        let differences = copy.differences(from: original)
        #expect(differences.map(\.id) == ["added", "changed", "removed"])
        #expect(differences.map(\.value) == ["— → new", "before → after", "old → —"])
    }

    @Test("Clearing inspection removes its selection without touching conversion imports")
    @MainActor
    func clearInspection() {
        let inspection = PhotoInspectionSession()
        let imports = PhotoImportSession()
        imports.pickerItems = [PhotosPickerItem(itemIdentifier: "conversion")]
        inspection.clear()
        #expect(inspection.pickerItems.isEmpty)
        #expect(inspection.photos.isEmpty)
        #expect(!inspection.isLoading)
        #expect(imports.pickerItems.count == 1)
    }

    @Test("Unsupported imports are skipped and read failures stay failures")
    @MainActor
    func importedConversionSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unsupportedURL = directory.appendingPathComponent("Screenshot.PNG")
        try Data("unsupported format without style data".utf8).write(to: unsupportedURL)
        let photo = SelectedPhoto(
            sourceURL: unsupportedURL,
            assetIdentifier: nil,
            preview: UIImage(),
            pixelSize: .zero,
            fileName: "Screenshot.PNG"
        )
        let coordinator = BatchConversionCoordinator()
        await coordinator.convertImportedPhotos(
            [photo], replacingOriginal: false,
            skippedDuringImport: 1, importFailures: ["Unable to read photo"]
        )
        guard case let .completed(summary) = coordinator.phase else {
            Issue.record("Expected a completion summary")
            return
        }
        #expect(summary.total == 3)
        #expect(summary.succeeded == 0)
        #expect(summary.skipped == 2)
        #expect(summary.failed == 1)
    }

    @Test("Clearing imports resets the system picker selection")
    @MainActor
    func clearImports() {
        let session = PhotoImportSession()
        session.pickerItems = [PhotosPickerItem(itemIdentifier: "test-asset")]
        session.clear()
        #expect(session.pickerItems.isEmpty)
        #expect(!session.hasSelection)
        #expect(session.loadingProgress == nil)
    }

    @Test("Each completed batch gets a durable, unique report")
    @MainActor
    func durableBatchReport() async throws {
        let coordinator = BatchConversionCoordinator()
        await coordinator.convertImportedPhotos([], replacingOriginal: false, skippedDuringImport: 3)
        let first = try #require(coordinator.report)
        #expect(first.summary.skipped == 3)
        coordinator.reset()
        #expect(coordinator.report == nil)
        await coordinator.convertImportedPhotos([], replacingOriginal: false, skippedDuringImport: 3)
        let second = try #require(coordinator.report)
        #expect(second.id != first.id)
        #expect(second.summary == first.summary)
    }

    @Test("Shortcut processes multiple unsupported input files independently")
    @MainActor
    func shortcutMultipleInputs() async {
        let files = (1...3).map { IntentFile(data: Data("unsupported".utf8), filename: "Photo\($0).png", type: .png) }
        let summary = await ConvertPhotosIntent.convertFiles(files)
        #expect(summary.total == 3)
        #expect(summary.skipped == 3)
        #expect(summary.failed == 0)
    }

    @Test("English language returns English copy")
    @MainActor
    func localizedCopy() {
        #expect(AppPreferences.Language.english.text(zh: "照片", en: "Photos") == "Photos")
        #expect(AppPreferences.Language.simplifiedChinese.text(zh: "照片", en: "Photos") == "照片")
    }

    @Test("Replacing the original is off by default")
    @MainActor
    func replacementDefault() {
        let suiteName = "StylePortTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.replaceOriginal == false)
    }

    @Test("Bundled Styles 3 template contains only required payloads")
    func templateContract() throws {
        let template = try Styles3Template.bundled()

        #expect(template.payloads.count == 3)
        #expect(template.blackMatte?.isEmpty == false)
        #expect(template.matteXMP?.isEmpty == false)
        #expect(template.textureStyles?.isEmpty == false)
    }

    @Test("Invalid HEIC input is rejected")
    func invalidInput() throws {
        let template = try Styles3Template.bundled()

        #expect(throws: HEIFError.self) {
            try Styles3Transplanter().convert(source: Data("not a HEIC".utf8), template: template)
        }
    }

    @Test("Batch result reports partial failures")
    func batchResult() {
        let converted = ConvertedPhoto(
            outputURL: URL(fileURLWithPath: "/tmp/output.heic"),
            replacedOriginal: false,
            filename: "IMG_0001_GP.HEIC"
        )
        let successful = BatchConversionResult(convertedPhotos: [converted], failures: [])
        let partial = BatchConversionResult(convertedPhotos: [converted], failures: ["IMG_0001.HEIC: failed"])

        #expect(successful.isFullySuccessful)
        #expect(!partial.isFullySuccessful)
    }

    @Test("Converted filenames preserve the original stem")
    func outputFilename() {
        #expect(PhotoConversionService.convertedFilename(from: "IMG_8952.HEIC") == "IMG_8952_GP.HEIC")
        #expect(PhotoConversionService.convertedFilename(from: nil) == "Photo_GP.HEIC")
    }

    @Test("Photo library save callback stays off the main actor")
    func photoLibrarySave() async throws {
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StylePort-PhotoLibrary-Test.png")
        try png.write(to: url, options: .atomic)

        let result = try await PhotoLibraryWriter.save(
            outputURL: url,
            replacingOriginal: false,
            assetIdentifier: nil
        )

        #expect(result.outputURL == url)
        #expect(!result.replacedOriginal)
    }
}
