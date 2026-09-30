import Foundation

nonisolated enum HEIFError: LocalizedError {
    case malformed(String)
    case unsupported(String)
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case let .malformed(message): "Invalid HEIC: \(message)"
        case let .unsupported(message): "Unsupported HEIC layout: \(message)"
        case let .incompatible(message): message
        }
    }
}

nonisolated struct HEIFBox: Sendable {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int

    var payloadStart: Int { start + headerSize }
    var end: Int { start + size }
}

nonisolated struct HEIFReader {
    let data: Data
    var offset: Int

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw HEIFError.malformed("unexpected end of data") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        (UInt16(try readUInt8()) << 8) | UInt16(try readUInt8())
    }

    mutating func readUInt24() throws -> UInt32 {
        (UInt32(try readUInt8()) << 16) | (UInt32(try readUInt8()) << 8) | UInt32(try readUInt8())
    }

    mutating func readUInt32() throws -> UInt32 {
        (UInt32(try readUInt8()) << 24)
            | (UInt32(try readUInt8()) << 16)
            | (UInt32(try readUInt8()) << 8)
            | UInt32(try readUInt8())
    }

    mutating func readUInt64() throws -> UInt64 {
        (UInt64(try readUInt32()) << 32) | UInt64(try readUInt32())
    }

    mutating func readUInt(byteCount: Int) throws -> UInt64 {
        guard (0...8).contains(byteCount) else { throw HEIFError.malformed("invalid integer width") }
        var value: UInt64 = 0
        for _ in 0..<byteCount {
            value = (value << 8) | UInt64(try readUInt8())
        }
        return value
    }

    mutating func readFourCC() throws -> String {
        let bytes = try (0..<4).map { _ in try readUInt8() }
        guard let value = String(bytes: bytes, encoding: .isoLatin1) else {
            throw HEIFError.malformed("invalid box type")
        }
        return value
    }
}

nonisolated struct HEIFItem: Sendable {
    let id: UInt32
    let type: String
}

nonisolated struct HEIFExtent: Sendable {
    var index: UInt64
    var offset: UInt64
    let length: UInt64
}

nonisolated struct HEIFLocation: Sendable {
    let itemID: UInt32
    let constructionMethod: UInt16
    let dataReferenceIndex: UInt16
    var baseOffset: UInt64
    var extents: [HEIFExtent]
}

nonisolated struct HEIFIlocLayout: Sendable {
    let version: UInt8
    let flags: UInt32
    let offsetSize: Int
    let lengthSize: Int
    let baseOffsetSize: Int
    let indexSize: Int
}

nonisolated enum HEIFCodec {
    static func boxes(in data: Data, from start: Int, to end: Int) throws -> [HEIFBox] {
        guard start >= 0, end <= data.count, start <= end else {
            throw HEIFError.malformed("invalid box range")
        }
        var result: [HEIFBox] = []
        var position = start
        while position + 8 <= end {
            var reader = HEIFReader(data: data, offset: position)
            let size32 = Int(try reader.readUInt32())
            let type = try reader.readFourCC()
            let headerSize: Int
            let size: Int
            if size32 == 1 {
                guard position + 16 <= end else { throw HEIFError.malformed("truncated large box") }
                headerSize = 16
                let largeSize = try reader.readUInt64()
                guard largeSize <= UInt64(Int.max) else { throw HEIFError.unsupported("box exceeds address space") }
                size = Int(largeSize)
            } else if size32 == 0 {
                headerSize = 8
                size = end - position
            } else {
                headerSize = 8
                size = size32
            }
            guard size >= headerSize, position + size <= end else {
                throw HEIFError.malformed("invalid \(type) box size")
            }
            result.append(HEIFBox(type: type, start: position, headerSize: headerSize, size: size))
            position += size
        }
        guard position == end else { throw HEIFError.malformed("trailing bytes in box container") }
        return result
    }

    static func fullBox(_ box: HEIFBox, in data: Data) throws -> (UInt8, UInt32, HEIFReader) {
        var reader = HEIFReader(data: data, offset: box.payloadStart)
        let version = try reader.readUInt8()
        let flags = try reader.readUInt24()
        return (version, flags, reader)
    }

    static func items(in iinf: HEIFBox, data: Data) throws -> [HEIFItem] {
        let (version, _, initialReader) = try fullBox(iinf, in: data)
        var reader = initialReader
        let count = version == 0 ? Int(try reader.readUInt16()) : Int(try reader.readUInt32())
        let entries = try boxes(in: data, from: reader.offset, to: iinf.end)
        guard entries.count >= count else { throw HEIFError.malformed("iinf entry count mismatch") }
        return try entries.prefix(count).compactMap { entry in
            guard entry.type == "infe" else { return nil }
            let (entryVersion, _, initialEntryReader) = try fullBox(entry, in: data)
            var entryReader = initialEntryReader
            let itemID: UInt32
            switch entryVersion {
            case 2: itemID = UInt32(try entryReader.readUInt16())
            case 3...: itemID = try entryReader.readUInt32()
            default: return nil
            }
            _ = try entryReader.readUInt16()
            return HEIFItem(id: itemID, type: try entryReader.readFourCC())
        }
    }

    static func locations(in iloc: HEIFBox, data: Data) throws -> (HEIFIlocLayout, [HEIFLocation]) {
        let (version, flags, initialReader) = try fullBox(iloc, in: data)
        var reader = initialReader
        let first = try reader.readUInt8()
        let second = try reader.readUInt8()
        let layout = HEIFIlocLayout(
            version: version,
            flags: flags,
            offsetSize: Int(first >> 4),
            lengthSize: Int(first & 0x0f),
            baseOffsetSize: Int(second >> 4),
            indexSize: (version == 1 || version == 2) ? Int(second & 0x0f) : 0
        )
        let count = version < 2 ? Int(try reader.readUInt16()) : Int(try reader.readUInt32())
        var result: [HEIFLocation] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let itemID = version < 2 ? UInt32(try reader.readUInt16()) : try reader.readUInt32()
            let constructionMethod: UInt16
            if version == 1 || version == 2 {
                constructionMethod = try reader.readUInt16() & 0x000f
            } else {
                constructionMethod = 0
            }
            let dataReferenceIndex = try reader.readUInt16()
            let baseOffset = try reader.readUInt(byteCount: layout.baseOffsetSize)
            let extentCount = Int(try reader.readUInt16())
            var extents: [HEIFExtent] = []
            extents.reserveCapacity(extentCount)
            for _ in 0..<extentCount {
                let index = layout.indexSize > 0 ? try reader.readUInt(byteCount: layout.indexSize) : 0
                let offset = try reader.readUInt(byteCount: layout.offsetSize)
                let length = try reader.readUInt(byteCount: layout.lengthSize)
                extents.append(HEIFExtent(index: index, offset: offset, length: length))
            }
            result.append(HEIFLocation(
                itemID: itemID,
                constructionMethod: constructionMethod,
                dataReferenceIndex: dataReferenceIndex,
                baseOffset: baseOffset,
                extents: extents
            ))
        }
        return (layout, result)
    }

    static func serializeLocations(_ locations: [HEIFLocation], layout: HEIFIlocLayout) throws -> Data {
        var payload = Data()
        payload.append(layout.version)
        payload.appendUInt24(layout.flags)
        payload.append(UInt8((layout.offsetSize << 4) | layout.lengthSize))
        payload.append(UInt8((layout.baseOffsetSize << 4) | layout.indexSize))
        if layout.version < 2 {
            guard locations.count <= Int(UInt16.max) else { throw HEIFError.unsupported("too many HEIF items") }
            payload.appendBE(UInt16(locations.count))
        } else {
            payload.appendBE(UInt32(locations.count))
        }
        for location in locations {
            if layout.version < 2 {
                guard location.itemID <= UInt32(UInt16.max) else { throw HEIFError.unsupported("item id exceeds 16 bits") }
                payload.appendBE(UInt16(location.itemID))
            } else {
                payload.appendBE(location.itemID)
            }
            if layout.version == 1 || layout.version == 2 {
                payload.appendBE(location.constructionMethod & 0x000f)
            }
            payload.appendBE(location.dataReferenceIndex)
            try payload.appendUInt(location.baseOffset, byteCount: layout.baseOffsetSize)
            guard location.extents.count <= Int(UInt16.max) else { throw HEIFError.unsupported("too many item extents") }
            payload.appendBE(UInt16(location.extents.count))
            for extent in location.extents {
                if layout.indexSize > 0 { try payload.appendUInt(extent.index, byteCount: layout.indexSize) }
                try payload.appendUInt(extent.offset, byteCount: layout.offsetSize)
                try payload.appendUInt(extent.length, byteCount: layout.lengthSize)
            }
        }
        return try makeBox(type: "iloc", payload: payload)
    }

    static func makeBox(type: String, payload: Data) throws -> Data {
        guard type.utf8.count == 4 else { throw HEIFError.malformed("invalid four-character code") }
        let total = payload.count + 8
        guard total <= Int(UInt32.max) else { throw HEIFError.unsupported("box exceeds 32-bit size") }
        var data = Data()
        data.appendBE(UInt32(total))
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }

    static func raw(_ box: HEIFBox, in data: Data) -> Data {
        data[box.start..<box.end]
    }
}

nonisolated extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt24(_ value: UInt32) {
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt(_ value: UInt64, byteCount: Int) throws {
        guard (0...8).contains(byteCount) else { throw HEIFError.malformed("invalid integer width") }
        if byteCount < 8, value >= (UInt64(1) << UInt64(byteCount * 8)) {
            throw HEIFError.unsupported("offset does not fit HEIF field")
        }
        guard byteCount > 0 else { return }
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
