import Foundation
import Testing
import UIKit
import PhotosUI
import SwiftUI
import AppIntents
import AVFoundation
import ImageIO
@testable import StylePort

@Suite("StylePort basics")
struct StylePortTests {
    @Test("Embedded Live Photo extraction preserves both resources byte for byte")
    func embeddedLivePhotoResources() throws {
        let photo = try syntheticContainer(types: ["ftyp", "meta", "mdat"])
        let movie = try syntheticContainer(types: ["ftyp", "mdat", "moov"])
        let packaged = packageLivePhoto(photo: photo, movie: movie)
        let split = try #require(try EmbeddedLivePhoto.split(packaged))
        #expect(split.photo == photo)
        #expect(split.movie == movie)
        #expect(try EmbeddedLivePhoto.photoData(in: packaged) == photo)
        #expect(try EmbeddedLivePhoto.split(photo) == nil)
    }

    @Test("Invalid embedded Live Photo lengths and resources are rejected")
    func invalidEmbeddedLivePhoto() throws {
        let photo = try syntheticContainer(types: ["ftyp", "meta", "mdat"])
        let movie = try syntheticContainer(types: ["ftyp", "mdat", "moov"])
        let packaged = packageLivePhoto(photo: photo, movie: movie)
        var invalidLength = packaged
        invalidLength.replaceSubrange(invalidLength.count - 4..<invalidLength.count, with: Data(repeating: 0xff, count: 4))
        var invalidHeader = packaged
        invalidHeader[photo.count + 8] = 1
        let missingMovieHeader = packageLivePhoto(photo: photo,
            movie: try syntheticContainer(types: ["mdat", "moov"]))
        for invalid in [invalidLength, invalidHeader, missingMovieHeader] {
            #expect(throws: HEIFError.self) { try EmbeddedLivePhoto.split(invalid) }
        }
        // An ordinary ISO UUID box must not be mistaken for the transfer wrapper.
        var ordinary = photo
        ordinary.append(try HEIFCodec.makeBox(type: "uuid", payload: Data(repeating: 0, count: 16)))
        #expect(try EmbeddedLivePhoto.split(ordinary) == nil)
    }

    @Test("Movie-only style markers do not make a still photo convertible")
    func embeddedMovieEligibility() async throws {
        let photo = try syntheticContainer(types: ["ftyp", "meta", "mdat"])
        var movie = try syntheticContainer(types: ["ftyp", "mdat", "moov"])
        movie.append(try HEIFCodec.makeBox(type: "free", payload:
            Data("tag:apple.com,2023:photo:metadata:styles".utf8)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Packaged.HEIC")
        try packageLivePhoto(photo: photo, movie: movie).write(to: file)
        #expect(try await PhotoConversionService.eligibility(of: file) == .incompatible)
    }

    private func syntheticContainer(types: [String]) throws -> Data {
        try types.reduce(into: Data()) { result, type in
            result.append(try HEIFCodec.makeBox(type: type, payload: Data()))
        }
    }

    private func packageLivePhoto(photo: Data, movie: Data) -> Data {
        func little(_ value: UInt32) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        var result = photo
        result.append(little(UInt32(movie.count + 16)))
        result.append(Data("uuid".utf8))
        result.append(Data(repeating: 0, count: 8))
        result.append(movie)
        result.append(Data("livp".utf8))
        result.append(Data([2, 17, 0, 0]))
        result.append(little(UInt32(movie.count)))
        return result
    }

    // Opt-in only: local fixtures stay outside the repository and release app.
    @Test("Packaged HEIC import, conversion and Live Photo save round trip",
          .enabled(if: ProcessInfo.processInfo.environment["STYLEPORT_EMBEDDED_FIXTURE_DIR"] != nil))
    @MainActor
    func embeddedLivePhotoRoundTrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["STYLEPORT_EMBEDDED_FIXTURE_DIR"])
        let root = path == "app-tmp" ? FileManager.default.temporaryDirectory.appendingPathComponent("EmbeddedFixtures")
            : URL(fileURLWithPath: path)
        let source = root.appendingPathComponent("IMG_9505_20261009.HEIC")
        let bytes = try Data(contentsOf: source)
        let resources = try #require(try EmbeddedLivePhoto.split(bytes))
        let originalStyle = try PhotoMetadataReader.readStyleContainer(bytes)
        #expect(originalStyle.hasStyles && !originalStyle.hasTexture)
        let selected = try await PhotoImporter.readNamedFile(
            ExternalPhotoInput(url: source, originalFilename: source.lastPathComponent), assetIdentifier: nil)
        let movie = try #require(selected.pairedVideoURL)
        #expect(try Data(contentsOf: movie) == resources.movie)
        #expect(selected.fileName == source.lastPathComponent)
        #expect(try await PhotoConversionService.eligibility(of: selected.sourceURL) == .convertible)
        let output = try await PhotoConversionService().convert(sourceURL: selected.sourceURL, originalFilename: selected.fileName)
        let outputStyle = try PhotoMetadataReader.readStyleContainer(Data(contentsOf: output))
        #expect(outputStyle.hasTexture)
        #expect(outputStyle.primaryImageDigest == originalStyle.primaryImageDigest)
        let saved = try await PhotoLibraryWriter.save(outputURL: output, replacingOriginal: false,
            assetIdentifier: nil, pairedVideoURL: movie)
        let imported = try await PhotoAssetSource.load(identifier: try #require(saved.savedAssetIdentifier))
        try await expectTextureTrack(in: try #require(imported.pairedVideoURL))
        try expectOriginalTracksUnchanged(source: resources.movie, output: Data(contentsOf: try #require(imported.pairedVideoURL)))
        #expect(try await PhotoConversionService.eligibility(of: imported.url) == .alreadyConverted)
        let noStyles = root.appendingPathComponent("IMG_9507_20261009.HEIC")
        let noStylesPhoto = try await PhotoImporter.readNamedFile(
            ExternalPhotoInput(url: noStyles, originalFilename: noStyles.lastPathComponent), assetIdentifier: nil)
        #expect(noStylesPhoto.pairedVideoURL != nil)
        #expect(try await PhotoConversionService.eligibility(of: noStylesPhoto.sourceURL) == .incompatible)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test("Live Photo resources never mix edited photos with original videos")
    func liveResourceSelection() throws {
        let edited = try LivePhotoResources.resourceIndices(
            types: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo], requiresVideo: true)
        #expect(edited.photo == 2 && edited.video == 3)
        let fallback = try LivePhotoResources.resourceIndices(
            types: [.fullSizePhoto, .photo, .pairedVideo], requiresVideo: true)
        #expect(fallback.photo == 1 && fallback.video == 2)
        #expect(throws: LivePhotoError.missingVideo) {
            try LivePhotoResources.resourceIndices(types: [.photo], requiresVideo: true)
        }
        #expect(throws: LivePhotoError.missingVideo) {
            try LivePhotoResources.resourceIndices(types: [.fullSizePhoto, .pairedVideo], requiresVideo: true)
        }
        let still = try LivePhotoResources.resourceIndices(types: [.photo, .fullSizePhoto], requiresVideo: false)
        #expect(still.photo == 1 && still.video == nil)
    }

    @Test("Live Photo metadata requires the exact same nonempty identifier")
    func liveIdentifiers() throws {
        try LivePhotoResources.requireMatchingIdentifiers(photo: "A", video: "A")
        #expect(throws: LivePhotoError.invalidPair) {
            try LivePhotoResources.requireMatchingIdentifiers(photo: "A", video: "B")
        }
        #expect(throws: LivePhotoError.invalidPair) {
            try LivePhotoResources.requireMatchingIdentifiers(photo: nil, video: "A")
        }
    }

    @Test("Styles conversion can select an intact original pair without mixing edit resources")
    func originalResourceSelection() throws {
        let types: [PHAssetResourceType] = [.fullSizePhoto, .fullSizePairedVideo, .photo, .pairedVideo]
        let original = try LivePhotoResources.resourceIndices(types: types, requiresVideo: true,
                                                               preferOriginal: true)
        #expect(original.photo == 2 && original.video == 3)
        let still = try LivePhotoResources.resourceIndices(types: types, requiresVideo: false,
                                                            preferOriginal: true)
        #expect(still.photo == 2 && still.video == nil)
        #expect(throws: LivePhotoError.missingVideo) {
            try LivePhotoResources.resourceIndices(types: [.photo, .fullSizePairedVideo],
                                                    requiresVideo: true, preferOriginal: true)
        }
        #expect(throws: LivePhotoError.invalidPair) {
            try LivePhotoResources.resourceIndices(types: [.fullSizePhoto, .fullSizePairedVideo],
                                                    requiresVideo: true, preferOriginal: true)
        }
    }

    // Real camera originals, renders and native recipes remain local and opt-in.
    @Test("Edited Styles 2 conversion retains native edits, appearance and both Live pairs",
          .enabled(if: ProcessInfo.processInfo.environment["STYLEPORT_EDITED_FIXTURE_DIR"] != nil))
    @MainActor
    func editedStylesRoundTrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["STYLEPORT_EDITED_FIXTURE_DIR"])
        let root = path == "app-tmp" ? FileManager.default.temporaryDirectory.appendingPathComponent("EditedStylesFixtures")
            : URL(fileURLWithPath: path)
        let photo = root.appendingPathComponent("1-IMG_9238.HEIC")
        let movie = root.appendingPathComponent("9-IMG_9238.MOV")
        let edits = PhotoEditResources(adjustmentDataURL: root.appendingPathComponent("7-Adjustments.plist"),
            renderedPhotoURL: root.appendingPathComponent("5-FullSizeRender.heic"),
            renderedVideoURL: root.appendingPathComponent("10-FullSizeRender.mov"))
        let originalBytes = try Data(contentsOf: photo)
        let originalMovie = try Data(contentsOf: movie)
        let renderedBytes = try Data(contentsOf: edits.renderedPhotoURL)
        let renderedMovie = try Data(contentsOf: try #require(edits.renderedVideoURL))
        let recipeBytes = try Data(contentsOf: edits.adjustmentDataURL)
        #expect(try await PhotoConversionService.eligibility(of: photo) == .convertible)
        #expect(try await PhotoConversionService.eligibility(of: edits.renderedPhotoURL) == .incompatible)
        let fixture = try await PhotoLibraryWriter.save(outputURL: photo, outputFilename: "IMG_9238.HEIC",
            replacingOriginal: false, assetIdentifier: nil, pairedVideoURL: movie, edits: edits)
        let fixtureID = try #require(fixture.savedAssetIdentifier)
        let inspected = try await PhotoAssetSource.load(identifier: fixtureID, forConversion: false)
        #expect(try Data(contentsOf: inspected.url) == renderedBytes)
        #expect(inspected.edits == nil)
        let source = try await PhotoAssetSource.load(identifier: fixtureID)
        let sourceEdits = try #require(source.edits)
        #expect(source.originalFilename == "IMG_9238.HEIC")
        #expect(try Data(contentsOf: source.url) == originalBytes)
        #expect(try Data(contentsOf: try #require(source.pairedVideoURL)) == originalMovie)
        #expect(try Data(contentsOf: sourceEdits.renderedPhotoURL) == renderedBytes)
        try expectNativeRecipeUnchanged(source: recipeBytes,
            output: Data(contentsOf: sourceEdits.adjustmentDataURL))
        let selected = try await PhotoImporter.readNamedFile(ExternalPhotoInput(url: source.url,
            originalFilename: source.originalFilename, pairedVideoURL: source.pairedVideoURL, edits: source.edits),
            assetIdentifier: fixtureID)
        #expect(selected.edits != nil)
        #expect(try await PhotoConversionService.eligibility(of: selected.sourceURL) == .convertible)
        let output = try await PhotoConversionService().convert(sourceURL: selected.sourceURL,
                                                               originalFilename: selected.fileName)
        let oldStyle = try PhotoMetadataReader.readStyleContainer(originalBytes)
        let newStyle = try PhotoMetadataReader.readStyleContainer(Data(contentsOf: output))
        #expect(newStyle.hasStyles && newStyle.hasTexture)
        #expect(oldStyle.primaryImageDigest == newStyle.primaryImageDigest)
        let saved = try await PhotoLibraryWriter.save(outputURL: output, replacingOriginal: false,
            assetIdentifier: fixtureID, pairedVideoURL: selected.pairedVideoURL, edits: selected.edits)
        let savedID = try #require(saved.savedAssetIdentifier)
        let converted = try await PhotoAssetSource.load(identifier: savedID)
        #expect(try await PhotoConversionService.eligibility(of: converted.url) == .alreadyConverted)
        let convertedEdits = try #require(converted.edits)
        #expect(try Data(contentsOf: convertedEdits.renderedPhotoURL) == renderedBytes)
        #expect(try Data(contentsOf: try #require(convertedEdits.renderedVideoURL)) == renderedMovie)
        try expectNativeRecipeUnchanged(source: recipeBytes,
            output: Data(contentsOf: convertedEdits.adjustmentDataURL))
        try await expectTextureTrack(in: try #require(converted.pairedVideoURL))
        try expectOriginalTracksUnchanged(source: originalMovie,
                                         output: Data(contentsOf: try #require(converted.pairedVideoURL)))
        let asset = try #require(PHAsset.fetchAssets(withLocalIdentifiers: [savedID], options: nil).firstObject)
        #expect(asset.mediaSubtypes.contains(.photoLive))
        let editingOptions = PHContentEditingInputRequestOptions()
        editingOptions.canHandleAdjustmentData = { _ in true }
        let adjustment: (String, String, Data)? = try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: editingOptions) { input, _ in
                guard let input else { continuation.resume(throwing: PhotoImportError.unavailable); return }
                continuation.resume(returning: input.adjustmentData.map {
                    ($0.formatIdentifier, $0.formatVersion, $0.data)
                })
            }
        }
        let actualRecipe = try #require(adjustment)
        let recipe = try #require(try PropertyListSerialization.propertyList(from: recipeBytes, format: nil)
                                 as? [String: Any])
        #expect(actualRecipe.0 == recipe["adjustmentFormatIdentifier"] as? String)
        #expect(actualRecipe.1 == recipe["adjustmentFormatVersion"] as? String)
        #expect(actualRecipe.2 == recipe["adjustmentData"] as? Data)
        #expect(try Data(contentsOf: photo) == originalBytes)
        let retained = try await PhotoAssetSource.load(identifier: fixtureID)
        #expect(try Data(contentsOf: retained.url) == originalBytes)
    }

    private func expectNativeRecipeUnchanged(source: Data, output: Data) throws {
        let before = try #require(try PropertyListSerialization.propertyList(from: source, format: nil)
                                  as? [String: Any])
        let after = try #require(try PropertyListSerialization.propertyList(from: output, format: nil)
                                 as? [String: Any])
        // PhotoKit reserializes the wrapper and updates its bookkeeping. The
        // editor identifier/version and actual native recipe must be identical.
        #expect(before["adjustmentData"] as? Data == after["adjustmentData"] as? Data)
        for key in ["adjustmentFormatIdentifier", "adjustmentFormatVersion", "adjustmentEditorBundleID"] {
            #expect(before[key] as? String == after[key] as? String)
        }
        #expect(before["adjustmentBaseVersion"] as? Int == after["adjustmentBaseVersion"] as? Int)
    }

    @Test("A Live Photo still without its movie cannot be saved")
    @MainActor
    func missingLiveVideo() async throws {
        let photo = try makeLiveStill(identifier: UUID().uuidString)
        #expect(LivePhotoResources.photoIdentifier(at: photo) != nil)
        await #expect(throws: LivePhotoError.missingVideo) {
            try await PhotoLibraryWriter.save(outputURL: photo, replacingOriginal: false, assetIdentifier: nil)
        }
    }

    @Test("Sharing and Shortcuts report missing Live video instead of producing a still")
    @MainActor
    func externalMissingLiveVideo() async throws {
        let photo = try makeLiveStill(identifier: UUID().uuidString)
        var data = try Data(contentsOf: photo)
        data.append(Data("tag:apple.com,2023:photo:metadata:styles".utf8))
        try data.write(to: photo)
        let shared = await ExternalPhotoConversion.convert([
            ExternalPhotoInput(url: photo, originalFilename: photo.lastPathComponent)])
        #expect(shared.failed == 1 && shared.succeeded == 0 && shared.skipped == 0)
        #expect(shared.failureMessages.first?.contains("Live Photo") == true)
        let shortcut = await ConvertPhotosIntent.convertFiles([
            IntentFile(data: data, filename: photo.lastPathComponent, type: .jpeg)])
        #expect(shortcut.failed == 1 && shortcut.succeeded == 0 && shortcut.skipped == 0)
        #expect(shortcut.failureMessages.first?.contains("Live Photo") == true)
    }

    // Opt-in integration test with a local original HEIC; personal photos are never bundled.
    @Test("Converted Live Photo includes texture timing without changing original media",
          .enabled(if: ProcessInfo.processInfo.environment["STYLEPORT_LIVE_HEIC_FIXTURE"] != nil))
    @MainActor
    func convertedHEICLivePhoto() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["STYLEPORT_LIVE_HEIC_FIXTURE"])
        let source = URL(fileURLWithPath: path)
        let identifier = try #require(LivePhotoResources.photoIdentifier(at: source))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = try await makeLiveMovie(identifier: identifier, directory: directory)
        let bytes = try Data(contentsOf: movie)
        let output = try await PhotoConversionService().convert(sourceURL: source, originalFilename: source.lastPathComponent)
        #expect(LivePhotoResources.photoIdentifier(at: output) == identifier)
        let saved = try await PhotoLibraryWriter.save(outputURL: output, replacingOriginal: false,
            assetIdentifier: nil, pairedVideoURL: movie)
        let imported = try await PhotoAssetSource.load(identifier: try #require(saved.savedAssetIdentifier))
        let importedMovie = try #require(imported.pairedVideoURL)
        try await expectTextureTrack(in: importedMovie)
        try expectOriginalTracksUnchanged(source: bytes, output: Data(contentsOf: importedMovie))
        let repeated = try await LivePhotoMovieConverter.convert(videoURL: importedMovie, photoURL: imported.url)
        #expect(repeated == importedMovie)
        #expect(try await PhotoConversionService.eligibility(of: imported.url) == .alreadyConverted)
    }

    @Test("Texture metadata track preserves media, duration and the Live Photo pairing")
    @MainActor
    func liveTextureTrack() async throws {
        let photo = try makeLiveStill(identifier: UUID().uuidString)
        let identifier = try #require(LivePhotoResources.photoIdentifier(at: photo))
        let movie = try await makeLiveMovie(identifier: identifier, directory: photo.deletingLastPathComponent())
        let original = try Data(contentsOf: movie)
        let nativeTexture = try #require(try Styles3Template.bundled().textureStyles)
        let payload = try LivePhotoMovieConverter.videoMetadata(from: nativeTexture)
        let dictionary = try #require(try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any])
        #expect(dictionary["CaptureMode"] as? String == "Video")
        #expect(dictionary["HardwareModel"] as? String == "iPhone19,7")
        let donor = try await makeTextureMovie(payload: payload, directory: photo.deletingLastPathComponent())
        let donorData = try Data(contentsOf: donor)
        let outputData = try QuickTimeMetadataTransplanter.addingTrack(source: original, metadataMovie: donorData)
        try expectOriginalTracksUnchanged(source: original, output: outputData)
        let output = photo.deletingLastPathComponent().appendingPathComponent("TextureFixture.MOV")
        try outputData.write(to: output)
        try await expectTextureTrack(in: output)
        try await LivePhotoResources.validate(photoURL: photo, videoURL: output)
        let originalDuration = try await AVURLAsset(url: movie).load(.duration)
        #expect(try await AVURLAsset(url: output).load(.duration) == originalDuration)
        let originalMetadata = try await AVURLAsset(url: movie).load(.metadata)
        let newMetadata = try await AVURLAsset(url: output).load(.metadata)
        #expect(originalMetadata.count == newMetadata.count)
        // Also exercise a legal size-zero final mdat atom. Appended atoms must not
        // become part of that old mdat, and the old sample offsets must still work.
        let top = try HEIFCodec.boxes(in: original, from: 0, to: original.count)
        let movieBox = try #require(top.first(where: { $0.type == "moov" }))
        let mediaBox = try #require(top.first(where: { $0.type == "mdat" }))
        var reordered = original
        reordered.replaceSubrange(movieBox.start + 4..<movieBox.start + 8, with: Data("free".utf8))
        reordered.append(Data(HEIFCodec.raw(movieBox, in: original)))
        var emptyMedia = try HEIFCodec.makeBox(type: "mdat", payload: Data())
        emptyMedia.replaceSubrange(0..<4, with: Data(repeating: 0, count: 4))
        reordered.append(emptyMedia)
        let zeroOutput = try QuickTimeMetadataTransplanter.addingTrack(source: reordered, metadataMovie: donorData)
        #expect(zeroOutput[mediaBox.start..<mediaBox.end] == original[mediaBox.start..<mediaBox.end])
        let zeroURL = photo.deletingLastPathComponent().appendingPathComponent("ZeroSizeFixture.MOV")
        try zeroOutput.write(to: zeroURL)
        try await expectTextureTrack(in: zeroURL)
        try await LivePhotoResources.validate(photoURL: photo, videoURL: zeroURL)
        #expect(throws: (any Error).self) { try QuickTimeMetadataTransplanter.header(in: Data()) }
        #expect(throws: (any Error).self) {
            try QuickTimeMetadataTransplanter.addingTrack(source: original, metadataMovie: Data())
        }
    }

    private func expectOriginalTracksUnchanged(source: Data, output: Data) throws {
        let oldTop = try HEIFCodec.boxes(in: source, from: 0, to: source.count)
        let newTop = try HEIFCodec.boxes(in: output, from: 0, to: output.count)
        for box in oldTop where box.type == "mdat" {
            #expect(source[box.start..<box.end] == output[box.start..<box.end])
        }
        let oldMovie = try #require(oldTop.first(where: { $0.type == "moov" }))
        let newMovie = try #require(newTop.first(where: { $0.type == "moov" }))
        let oldTracks = try HEIFCodec.boxes(in: source, from: oldMovie.payloadStart, to: oldMovie.end).filter { $0.type == "trak" }
        let newTracks = try HEIFCodec.boxes(in: output, from: newMovie.payloadStart, to: newMovie.end).filter { $0.type == "trak" }
        #expect(newTracks.count == oldTracks.count + 1)
        for (old, new) in zip(oldTracks, newTracks) {
            #expect(source[old.start..<old.end] == output[new.start..<new.end])
        }
    }

    private func expectTextureTrack(in url: URL) async throws {
        let asset = AVURLAsset(url: url)
        var textureTracks = 0
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let formats = try await track.load(.formatDescriptions)
            guard formats.contains(where: {
                (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? []).contains(LivePhotoMovieConverter.textureIdentifier.rawValue)
            }) else { continue }
            textureTracks += 1
            let associations = try await track.load(.availableTrackAssociationTypes)
            #expect(associations.contains(.metadataReferent))
            let metadataReferents = try await track.loadAssociatedTracks(ofType: .metadataReferent)
            let metadataReferent = try #require(metadataReferents.first)
            #expect(metadataReferents.count == 1 && metadataReferent.mediaType == .video)
            if #available(iOS 26.0, *) {
                #expect(associations.contains(.renderMetadataSource))
                let renderTargets = try await track.loadAssociatedTracks(ofType: .renderMetadataSource)
                let renderTarget = try #require(renderTargets.first)
                #expect(renderTargets.count == 1 && renderTarget.mediaType == .video)
                #expect(metadataReferent.trackID == renderTarget.trackID)
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            reader.add(output)
            #expect(reader.startReading())
            var groups: [AVTimedMetadataGroup] = []
            while let group = adaptor.nextTimedMetadataGroup() { groups.append(group) }
            #expect(reader.status == .completed)
            let first = try #require(groups.first)
            #expect(first.timeRange.start == .zero)
            var end = first.timeRange.end
            for group in groups {
                let item = try #require(group.items.first)
                #expect(item.identifier == LivePhotoMovieConverter.textureIdentifier)
                let data = try #require(item.dataValue)
                let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
                #expect(plist["CaptureMode"] as? String == "Video")
                #expect(group.timeRange.start <= end)
                if group.timeRange.end > end { end = group.timeRange.end }
            }
            #expect(end >= (try await asset.load(.duration)))
        }
        #expect(textureTracks == 1)
    }

    private func makeTextureMovie(payload: Data, directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("TextureDonor.MOV")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = 600
        var format: CMMetadataFormatDescription?
        let identifier = LivePhotoMovieConverter.textureIdentifier.rawValue
        #expect(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.raw-data"]] as CFArray,
            formatDescriptionOut: &format) == noErr)
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem()
        item.identifier = LivePhotoMovieConverter.textureIdentifier
        item.dataType = "com.apple.metadata.datatype.raw-data"
        item.value = payload as NSData
        #expect(adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test("A provider claiming Live Photo cannot silently fall back to its still image")
    @MainActor
    func failedLiveProvider() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: try #require(PHLivePhoto.readableTypeIdentifiersForItemProvider.first),
                                             visibility: .all) { completion in
            completion(nil, LivePhotoError.missingVideo)
            return nil
        }
        #expect(provider.canLoadObject(ofClass: PHLivePhoto.self))
        await #expect(throws: (any Error).self) {
            try await LivePhotoResources.providerInput(provider)
        }
    }

    @Test("Saving and reimporting a Live Photo retains its movie bytes and dynamic subtype")
    @MainActor
    func livePhotoRoundTrip() async throws {
        let identifier = UUID().uuidString
        let photo = try makeLiveStill(identifier: identifier)
        let movie = try await makeLiveMovie(identifier: identifier, directory: photo.deletingLastPathComponent())
        let movieData = try Data(contentsOf: movie)
        let otherPhoto = try makeLiveStill(identifier: UUID().uuidString)
        await #expect(throws: LivePhotoError.invalidPair) {
            try await LivePhotoResources.validate(photoURL: otherPhoto, videoURL: movie)
        }
        try await LivePhotoResources.validate(photoURL: photo, videoURL: movie)
        let saved = try await PhotoLibraryWriter.save(outputURL: photo, replacingOriginal: false,
            assetIdentifier: nil, pairedVideoURL: movie)
        let savedID = try #require(saved.savedAssetIdentifier)
        let asset = try #require(PHAsset.fetchAssets(withLocalIdentifiers: [savedID], options: nil).firstObject)
        #expect(asset.mediaSubtypes.contains(.photoLive))
        let imported = try await PhotoAssetSource.load(identifier: savedID)
        let importedMovie = try #require(imported.pairedVideoURL)
        #expect(try Data(contentsOf: importedMovie) == movieData)
        #expect(LivePhotoResources.photoIdentifier(at: imported.url) == identifier)
        await #expect(throws: LivePhotoError.missingVideo) {
            try await PhotoLibraryWriter.save(outputURL: imported.url, replacingOriginal: true,
                assetIdentifier: savedID)
        }
        #expect(PHAsset.fetchAssets(withLocalIdentifiers: [savedID], options: nil).count == 1)
        let unmarkedStill = imported.url.deletingLastPathComponent().appendingPathComponent("Unmarked.PNG")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: unmarkedStill)
        await #expect(throws: LivePhotoError.missingVideo) {
            try await PhotoLibraryWriter.save(outputURL: unmarkedStill, replacingOriginal: true,
                assetIdentifier: savedID)
        }
        #expect(PHAsset.fetchAssets(withLocalIdentifiers: [savedID], options: nil).count == 1)
        // Keep this synthetic simulator fixture: deletion requires a user confirmation dialog.
    }

    @MainActor
    private func makeLiveStill(identifier: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("LiveFixture.JPG")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage),
            [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @MainActor
    private func makeLiveMovie(identifier: String, directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("LiveFixture.MOV")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let idItem = AVMutableMetadataItem()
        idItem.identifier = .quickTimeMetadataContentIdentifier
        idItem.value = identifier as NSString
        writer.metadata = [idItem]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(video)
        let metadataID = "mdta/com.apple.quicktime.still-image-time"
        var format: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [[kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: metadataID,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8"]] as CFArray,
            formatDescriptionOut: &format)
        #expect(status == noErr)
        let timedInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                           sourceFormatHint: format)
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: timedInput)
        writer.add(timedInput)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let marker = AVMutableMetadataItem()
        marker.identifier = AVMetadataIdentifier(rawValue: metadataID)
        marker.dataType = "com.apple.metadata.datatype.int8"
        marker.value = NSNumber(value: 0)
        #expect(timed.append(AVTimedMetadataGroup(items: [marker], timeRange:
            CMTimeRange(start: CMTime(value: 15, timescale: 30), duration: CMTime(value: 1, timescale: 30)))))
        timedInput.markAsFinished()
        for frame in 0..<30 {
            while !video.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? LivePhotoError.invalidPair }
                try await Task.sleep(for: .milliseconds(10))
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(pixels.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                memset(base, Int32(frame * 8), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            #expect(pixels.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

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
        inspection.clear()
        #expect(inspection.pickerItems.isEmpty)
        #expect(inspection.photos.isEmpty)
        #expect(!inspection.isLoading)
        #expect(imports.loadingProgress == nil)
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
