import Foundation

/// Some transfer tools append a movie and a `livp` footer to a HEIC instead of
/// exporting the two Live Photo resources separately. This is not an ISO UUID
/// box: its length is little-endian and it has a separate twelve-byte footer.
nonisolated enum EmbeddedLivePhoto {
    struct Resources: Sendable, Equatable {
        let photo: Data
        let movie: Data
    }

    static func split(_ data: Data) throws -> Resources? {
        guard data.count >= 12,
              data.suffix(12).prefix(4) == Data("livp".utf8) else { return nil }
        let movieLength = Int(littleEndianUInt32(data, at: data.count - 4))
        guard movieLength >= 8, data.count >= 28, movieLength <= data.count - 28 else {
            throw HEIFError.malformed("invalid embedded Live Photo movie length")
        }
        let header = data.count - 28 - movieLength
        guard header >= 8,
              data[(header + 4)..<(header + 8)] == Data("uuid".utf8),
              data[(header + 8)..<(header + 16)].allSatisfy({ $0 == 0 }),
              UInt64(littleEndianUInt32(data, at: header)) == UInt64(movieLength) + 16 else {
            throw HEIFError.malformed("invalid embedded Live Photo header")
        }
        let photo = Data(data.prefix(header))
        let movie = Data(data[(header + 16)..<(data.count - 12)])
        try validate(photo, requiring: ["ftyp", "meta", "mdat"])
        try validate(movie, requiring: ["ftyp", "moov", "mdat"])
        return Resources(photo: photo, movie: movie)
    }

    static func photoData(in data: Data) throws -> Data {
        try split(data)?.photo ?? data
    }

    private static func validate(_ data: Data, requiring types: Set<String>) throws {
        let boxes = try HEIFCodec.boxes(in: data, from: 0, to: data.count)
        guard boxes.first?.type == "ftyp", types.isSubset(of: Set(boxes.map(\.type))) else {
            throw HEIFError.malformed("embedded Live Photo resource is incomplete")
        }
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
    }
}
