import AVFoundation
import Foundation

nonisolated enum LivePhotoMovieConverter {
    static let textureIdentifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.texturestyle-info")
    private static let smartStyleIdentifier = "mdta/com.apple.quicktime.smartstyle-info"
    private static let textureURI = "tag:apple.com,2026:photo:metadata:texture_styles"

    /// Still and video must both expose the Styles 3 inputs. A valid Live pairing alone
    /// does not guarantee that Photos can build its photographic-style editing pipeline.
    static func convert(videoURL: URL, photoURL: URL) async throws -> URL {
        guard let texture = try textureMetadata(in: Data(contentsOf: photoURL, options: .mappedIfSafe)) else {
            return videoURL
        }
        let asset = AVURLAsset(url: videoURL)
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            for format in try await track.load(.formatDescriptions) {
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(format) as? [String] ?? []
                if identifiers.contains(textureIdentifier.rawValue) { return videoURL }
            }
        }
        try Task.checkCancellation()
        let source = try Data(contentsOf: videoURL, options: .mappedIfSafe)
        let header = try QuickTimeMetadataTransplanter.header(in: source)
        let directory = photoURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("Texture-\(UUID().uuidString).MOV")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let payload = try videoMetadata(from: texture)
        let timeRanges = try await renderTimeRanges(in: asset, duration: CMTime(
            value: Int64(header.duration), timescale: Int32(header.timeScale)))
        try await writeMetadata(payload, header: header, timeRanges: timeRanges, to: temporary)
        try Task.checkCancellation()
        let donor = try Data(contentsOf: temporary)
        let output = try QuickTimeMetadataTransplanter.addingTrack(source: source, metadataMovie: donor)
        let destination = directory.appendingPathComponent(photoURL.deletingPathExtension().lastPathComponent + ".MOV")
        try output.write(to: destination, options: .atomic)
        return destination
    }

    static func videoMetadata(from texture: Data) throws -> Data {
        guard var properties = try PropertyListSerialization.propertyList(from: texture, format: nil) as? [String: Any] else {
            throw HEIFError.malformed("invalid texture style metadata")
        }
        // Still-image person masks cannot describe changing faces in a movie.
        properties.removeValue(forKey: "TextureStylePostProcessedPeopleData")
        properties.removeValue(forKey: "TextureStyleFaceAttitudeMetadata")
        properties["CaptureMode"] = "Video"
        return try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
    }

    private static func textureMetadata(in data: Data) throws -> Data? {
        // JPEG and other unconverted resources are left unchanged.
        guard data.range(of: Data(textureURI.utf8)) != nil else { return nil }
        let top = try HEIFCodec.boxes(in: data, from: 0, to: data.count)
        guard let meta = top.first(where: { $0.type == "meta" }) else { throw HEIFError.malformed("missing HEIC meta") }
        let children = try HEIFCodec.boxes(in: data, from: meta.payloadStart + 4, to: meta.end)
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else { throw HEIFError.malformed("missing HEIC items") }
        let (version, _, initial) = try HEIFCodec.fullBox(iinf, in: data)
        var reader = initial
        reader.offset += version == 0 ? 2 : 4
        let entries = try HEIFCodec.boxes(in: data, from: reader.offset, to: iinf.end)
        guard let entry = entries.first(where: {
            data[$0.start..<$0.end].range(of: Data(textureURI.utf8)) != nil
        }) else { throw HEIFError.malformed("missing texture item") }
        let (itemVersion, _, itemReader) = try HEIFCodec.fullBox(entry, in: data)
        var idReader = itemReader
        let id = itemVersion == 2 ? UInt32(try idReader.readUInt16()) : try idReader.readUInt32()
        let (_, locations) = try HEIFCodec.locations(in: iloc, data: data)
        guard let location = locations.first(where: { $0.itemID == id }), location.dataReferenceIndex == 0 else {
            throw HEIFError.malformed("missing texture payload")
        }
        let base: UInt64
        switch location.constructionMethod {
        case 0: base = location.baseOffset
        case 1:
            guard let idat = children.first(where: { $0.type == "idat" }) else { throw HEIFError.malformed("missing idat") }
            base = UInt64(idat.payloadStart) + location.baseOffset
        default: throw HEIFError.unsupported("texture item construction method")
        }
        var result = Data()
        for extent in location.extents {
            guard base <= UInt64(data.count), extent.offset <= UInt64(data.count) - base,
                  extent.length <= UInt64(data.count) - base - extent.offset else {
                throw HEIFError.malformed("texture extent outside HEIC")
            }
            let start = Int(base + extent.offset)
            result.append(data[start..<(start + Int(extent.length))])
        }
        return result
    }

    /// Photos' final Live Photo renderer consumes style control data as timed
    /// samples. One long-lived metadata sample is visible to AVFoundation, but
    /// is not reliably forwarded by every Neutrino render node. Mirror the
    /// camera's smart-style sample timing so every render interval has texture
    /// data available.
    private static func renderTimeRanges(in asset: AVAsset, duration: CMTime) async throws -> [CMTimeRange] {
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let formats = try await track.load(.formatDescriptions)
            let isSmartStyle = formats.contains {
                (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String] ?? [])
                    .contains(smartStyleIdentifier)
            }
            guard isSmartStyle else { continue }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.canAdd(output) else { throw HEIFError.malformed("could not read smart-style timing") }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? HEIFError.malformed("could not start smart-style timing reader")
            }
            var ranges: [CMTimeRange] = []
            while let group = adaptor.nextTimedMetadataGroup() {
                guard group.timeRange.isValid, !group.timeRange.isEmpty else { continue }
                ranges.append(group.timeRange)
            }
            guard reader.status == .completed else {
                throw reader.error ?? HEIFError.malformed("could not finish smart-style timing reader")
            }
            if covers(duration: duration, ranges: ranges) { return ranges }
        }
        return [CMTimeRange(start: .zero, duration: duration)]
    }

    private static func covers(duration: CMTime, ranges: [CMTimeRange]) -> Bool {
        guard let first = ranges.first, first.start <= .zero else { return false }
        var end = first.end
        for range in ranges.dropFirst() {
            guard range.start <= end else { return false }
            if range.end > end { end = range.end }
        }
        return end >= duration
    }

    private static func writeMetadata(_ data: Data, header: QuickTimeMetadataTransplanter.MovieHeader,
                                      timeRanges: [CMTimeRange], to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = Int32(header.timeScale)
        var format: CMMetadataFormatDescription?
        let rawType = "com.apple.metadata.datatype.raw-data"
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [[kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: textureIdentifier.rawValue,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: rawType]] as CFArray,
            formatDescriptionOut: &format)
        guard status == noErr, let format else { throw HEIFError.malformed("could not create texture metadata format") }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let duration = CMTime(value: Int64(header.duration), timescale: Int32(header.timeScale))
        func group(for timeRange: CMTimeRange) -> AVTimedMetadataGroup {
            let item = AVMutableMetadataItem()
            item.identifier = textureIdentifier
            item.dataType = rawType
            item.value = data as NSData
            return AVTimedMetadataGroup(items: [item], timeRange: timeRange)
        }
        do {
            if #available(iOS 26.0, *) {
                let receiver = writer.inputMetadataReceiver(for: input)
                try writer.start()
                writer.startSession(atSourceTime: .zero)
                for timeRange in timeRanges {
                    try Task.checkCancellation()
                    try await receiver.append(group(for: timeRange))
                }
                receiver.finish()
            } else {
                let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? LivePhotoError.invalidPair }
                writer.startSession(atSourceTime: .zero)
                for timeRange in timeRanges {
                    try Task.checkCancellation()
                    guard adaptor.append(group(for: timeRange)) else {
                        throw writer.error ?? LivePhotoError.invalidPair
                    }
                }
                input.markAsFinished()
            }
            writer.endSession(atSourceTime: duration)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LivePhotoError.invalidPair }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }
}
