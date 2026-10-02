import Foundation

/// Adds an AVAssetWriter-generated metadata track without remuxing the original movie.
/// Original tracks and media offsets stay intact, including Apple's Live Photo metadata.
nonisolated enum QuickTimeMetadataTransplanter {
    struct MovieHeader {
        let timeScale: UInt32
        let duration: UInt64
        let nextTrackID: UInt32
    }

    static func header(in data: Data) throws -> MovieHeader {
        let top = try HEIFCodec.boxes(in: data, from: 0, to: data.count)
        guard let movie = top.first(where: { $0.type == "moov" }),
              let header = try children(of: movie, in: data).first(where: { $0.type == "mvhd" })
        else { throw HEIFError.malformed("MOV movie header is missing") }
        let (version, _, initial) = try HEIFCodec.fullBox(header, in: data)
        guard version <= 1 else { throw HEIFError.unsupported("MOV header version") }
        var reader = initial
        reader.offset += version == 1 ? 16 : 8
        let timeScale = try reader.readUInt32()
        let duration = version == 1 ? try reader.readUInt64() : UInt64(try reader.readUInt32())
        reader.offset = header.end - 4
        let nextID = try reader.readUInt32()
        guard timeScale > 0, timeScale <= UInt32(Int32.max), duration > 0,
              duration <= UInt64(Int64.max), nextID > 0, nextID < UInt32.max
        else { throw HEIFError.malformed("invalid MOV duration or track identifier") }
        return MovieHeader(timeScale: timeScale, duration: duration, nextTrackID: nextID)
    }

    static func addingTrack(source: Data, metadataMovie: Data) throws -> Data {
        let sourceHeader = try header(in: source)
        let donorHeader = try header(in: metadataMovie)
        guard sourceHeader.timeScale == donorHeader.timeScale,
              sourceHeader.duration == donorHeader.duration
        else { throw HEIFError.malformed("metadata track does not cover the Live Photo duration") }
        let top = try HEIFCodec.boxes(in: source, from: 0, to: source.count)
        let donorTop = try HEIFCodec.boxes(in: metadataMovie, from: 0, to: metadataMovie.count)
        guard let movie = top.first(where: { $0.type == "moov" }),
              let donorMovie = donorTop.first(where: { $0.type == "moov" }),
              let donorMedia = donorTop.first(where: { $0.type == "mdat" })
        else { throw HEIFError.malformed("MOV metadata track is incomplete") }
        guard !top.contains(where: { $0.type == "moof" }) else {
            throw HEIFError.unsupported("fragmented Live Photo movie")
        }
        let donorTracks = try children(of: donorMovie, in: metadataMovie).filter { $0.type == "trak" }
        guard donorTracks.count == 1 else { throw HEIFError.malformed("expected one generated metadata track") }
        let primaryTrackID = try primaryVideoTrackID(in: movie, data: source)
        let newMedia = try HEIFCodec.makeBox(type: "mdat", payload: Data(metadataMovie[donorMedia.payloadStart..<donorMedia.end]))
        let newMediaStart = source.count + 8
        let track = try rewriteTrack(donorTracks[0], data: metadataMovie,
                                    trackID: sourceHeader.nextTrackID,
                                    primaryTrackID: primaryTrackID,
                                    donorMedia: donorMedia, newMediaStart: newMediaStart)
        var moviePayload = Data()
        for child in try children(of: movie, in: source) {
            var raw = Data(HEIFCodec.raw(child, in: source))
            if child.type == "mvhd" { replaceUInt32(&raw, at: raw.count - 4, with: sourceHeader.nextTrackID + 1) }
            moviePayload.append(raw)
        }
        moviePayload.append(track)
        let newMovie = try HEIFCodec.makeBox(type: "moov", payload: moviePayload)
        var output = Data(capacity: source.count + newMedia.count + newMovie.count)
        for box in top {
            var raw = Data(HEIFCodec.raw(box, in: source))
            if box.type == "moov" {
                // Leave a same-size free atom: no original chunk offsets need to change.
                raw.replaceSubrange(4..<8, with: Data("free".utf8))
            }
            // A size-zero final atom must no longer swallow the appended metadata atoms.
            if raw.prefix(4) == Data(repeating: 0, count: 4) {
                guard raw.count <= Int(UInt32.max) else { throw HEIFError.unsupported("MOV atom exceeds 32 bits") }
                replaceUInt32(&raw, at: 0, with: UInt32(raw.count))
            }
            output.append(raw)
        }
        output.append(newMedia)
        output.append(newMovie)
        return output
    }

    private static func children(of box: HEIFBox, in data: Data) throws -> [HEIFBox] {
        try HEIFCodec.boxes(in: data, from: box.payloadStart, to: box.end)
    }

    private static func rewriteTrack(_ box: HEIFBox, data: Data, trackID: UInt32,
                                     primaryTrackID: UInt32,
                                     donorMedia: HEIFBox, newMediaStart: Int) throws -> Data {
        switch box.type {
        case "trak":
            var payload = Data()
            for child in try children(of: box, in: data) {
                payload.append(try rewriteTrack(child, data: data, trackID: trackID,
                                               primaryTrackID: primaryTrackID,
                                               donorMedia: donorMedia, newMediaStart: newMediaStart))
            }
            payload.append(try trackReferences(to: primaryTrackID))
            return try HEIFCodec.makeBox(type: box.type, payload: payload)
        case "mdia", "minf", "stbl":
            var payload = Data()
            for child in try children(of: box, in: data) {
                payload.append(try rewriteTrack(child, data: data, trackID: trackID,
                                               primaryTrackID: primaryTrackID,
                                               donorMedia: donorMedia, newMediaStart: newMediaStart))
            }
            return try HEIFCodec.makeBox(type: box.type, payload: payload)
        case "tkhd":
            var raw = Data(HEIFCodec.raw(box, in: data))
            let version = data[box.payloadStart]
            guard version <= 1 else { throw HEIFError.unsupported("MOV track header version") }
            let idOffset = box.headerSize + (version == 1 ? 20 : 12)
            guard idOffset + 4 <= raw.count else { throw HEIFError.malformed("truncated MOV track header") }
            replaceUInt32(&raw, at: idOffset, with: trackID)
            return raw
        case "stco", "co64":
            let (version, flags, initial) = try HEIFCodec.fullBox(box, in: data)
            var reader = initial
            let count = try reader.readUInt32()
            let width = box.type == "stco" ? 4 : 8
            guard UInt64(count) * UInt64(width) == UInt64(box.end - reader.offset) else {
                throw HEIFError.malformed("MOV chunk offset table size mismatch")
            }
            var offsets: [UInt64] = []
            for _ in 0..<count {
                let offset = try reader.readUInt(byteCount: width)
                guard offset >= UInt64(donorMedia.payloadStart), offset < UInt64(donorMedia.end) else {
                    throw HEIFError.malformed("metadata chunk outside generated media")
                }
                offsets.append(UInt64(newMediaStart) + offset - UInt64(donorMedia.payloadStart))
            }
            let wide = box.type == "co64" || offsets.contains { $0 > UInt64(UInt32.max) }
            var payload = Data([version])
            payload.appendUInt24(flags)
            payload.appendBE(count)
            for offset in offsets { try payload.appendUInt(offset, byteCount: wide ? 8 : 4) }
            return try HEIFCodec.makeBox(type: wide ? "co64" : "stco", payload: payload)
        default:
            return Data(HEIFCodec.raw(box, in: data))
        }
    }

    private static func replaceUInt32(_ data: inout Data, at offset: Int, with value: UInt32) {
        var bytes = Data()
        bytes.appendBE(value)
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
    }

    /// Timed rendering metadata must explicitly refer to the primary video track.
    /// `cdsc` is AVTrackAssociationTypeMetadataReferent. Existing Apple timed
    /// style tracks also carry `cdep`; iOS 26+ uses `rndr` for
    /// AVTrackAssociationTypeRenderMetadataSource so AVVideoComposition
    /// delivers the sample to Apple's renderer.
    private static func trackReferences(to primaryTrackID: UInt32) throws -> Data {
        var reference = Data()
        reference.appendBE(primaryTrackID)
        var payload = try HEIFCodec.makeBox(type: "cdsc", payload: reference)
        payload.append(try HEIFCodec.makeBox(type: "cdep", payload: reference))
        payload.append(try HEIFCodec.makeBox(type: "rndr", payload: reference))
        return try HEIFCodec.makeBox(type: "tref", payload: payload)
    }

    private static func primaryVideoTrackID(in movie: HEIFBox, data: Data) throws -> UInt32 {
        for track in try children(of: movie, in: data) where track.type == "trak" {
            let trackChildren = try children(of: track, in: data)
            guard let media = trackChildren.first(where: { $0.type == "mdia" }),
                  let handler = try children(of: media, in: data).first(where: { $0.type == "hdlr" })
            else { continue }
            var handlerReader = HEIFReader(data: data, offset: handler.payloadStart + 8)
            guard handlerReader.offset + 4 <= handler.end,
                  try handlerReader.readFourCC() == "vide",
                  let header = trackChildren.first(where: { $0.type == "tkhd" })
            else { continue }
            let version = data[header.payloadStart]
            guard version <= 1 else { throw HEIFError.unsupported("MOV track header version") }
            var idReader = HEIFReader(data: data, offset: header.payloadStart + (version == 1 ? 20 : 12))
            let id = try idReader.readUInt32()
            guard id > 0 else { throw HEIFError.malformed("invalid primary video track identifier") }
            return id
        }
        throw HEIFError.malformed("primary Live Photo video track is missing")
    }
}
