import Foundation

struct Box {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int
    var payloadStart: Int { start + headerSize }
    var end: Int { start + size }
}

struct Reader {
    let data: Data
    var offset: Int

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() -> UInt16 {
        (UInt16(u8()) << 8) | UInt16(u8())
    }

    mutating func u24() -> UInt32 {
        (UInt32(u8()) << 16) | (UInt32(u8()) << 8) | UInt32(u8())
    }

    mutating func u32() -> UInt32 {
        (UInt32(u8()) << 24) | (UInt32(u8()) << 16) | (UInt32(u8()) << 8) | UInt32(u8())
    }

    mutating func u64() -> UInt64 {
        (UInt64(u32()) << 32) | UInt64(u32())
    }

    mutating func uint(bytes: Int) -> UInt64 {
        var result: UInt64 = 0
        for _ in 0..<bytes { result = (result << 8) | UInt64(u8()) }
        return result
    }

    mutating func fourCC() -> String {
        let bytes = (0..<4).map { _ in u8() }
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }

    mutating func cString(limit: Int) -> String {
        let start = offset
        while offset < limit, data[offset] != 0 { offset += 1 }
        let value = String(data: data[start..<offset], encoding: .utf8) ?? "<binary>"
        if offset < limit { offset += 1 }
        return value
    }
}

func boxes(in data: Data, from start: Int, to end: Int) -> [Box] {
    var result: [Box] = []
    var position = start
    while position + 8 <= end {
        var reader = Reader(data: data, offset: position)
        let size32 = Int(reader.u32())
        let type = reader.fourCC()
        let headerSize: Int
        let size: Int
        if size32 == 1 {
            guard position + 16 <= end else { break }
            headerSize = 16
            size = Int(reader.u64())
        } else if size32 == 0 {
            headerSize = 8
            size = end - position
        } else {
            headerSize = 8
            size = size32
        }
        guard size >= headerSize, position + size <= end else { break }
        result.append(Box(type: type, start: position, headerSize: headerSize, size: size))
        position += size
    }
    return result
}

struct Item {
    let id: UInt32
    let type: String
    let name: String
    let contentType: String?
    let boxStart: Int
    let boxSize: Int
}

struct Extent {
    let offset: UInt64
    let length: UInt64
}

struct Location {
    let id: UInt32
    let constructionMethod: UInt16
    let baseOffset: UInt64
    let extents: [Extent]
}

func fullBox(_ box: Box, data: Data) -> (version: UInt8, flags: UInt32, reader: Reader) {
    var reader = Reader(data: data, offset: box.payloadStart)
    let version = reader.u8()
    let flags = reader.u24()
    return (version, flags, reader)
}

func parseItems(_ box: Box, data: Data) -> [Item] {
    var (_, _, reader) = fullBox(box, data: data)
    let count = data[box.payloadStart] == 0 ? Int(reader.u16()) : Int(reader.u32())
    let entries = boxes(in: data, from: reader.offset, to: box.end)
    return entries.prefix(count).compactMap { entry in
        guard entry.type == "infe" else { return nil }
        var (version, _, r) = fullBox(entry, data: data)
        let id: UInt32
        if version == 2 {
            id = UInt32(r.u16())
        } else if version >= 3 {
            id = r.u32()
        } else {
            return nil
        }
        _ = r.u16()
        let type = r.fourCC()
        let name = r.cString(limit: entry.end)
        var contentType: String?
        if type == "mime" || type == "uri " {
            contentType = r.cString(limit: entry.end)
        }
        version = 0
        return Item(id: id, type: type, name: name, contentType: contentType, boxStart: entry.start, boxSize: entry.size)
    }
}

func parseLocations(_ box: Box, data: Data) -> [Location] {
    var (version, _, reader) = fullBox(box, data: data)
    let first = reader.u8()
    let second = reader.u8()
    let offsetSize = Int(first >> 4)
    let lengthSize = Int(first & 0x0f)
    let baseOffsetSize = Int(second >> 4)
    let indexSize = version == 1 || version == 2 ? Int(second & 0x0f) : 0
    let count = version < 2 ? Int(reader.u16()) : Int(reader.u32())
    var result: [Location] = []
    for _ in 0..<count {
        let id = version < 2 ? UInt32(reader.u16()) : reader.u32()
        let construction = version == 1 || version == 2 ? reader.u16() & 0x000f : 0
        _ = reader.u16()
        let base = reader.uint(bytes: baseOffsetSize)
        let extentCount = Int(reader.u16())
        var extents: [Extent] = []
        for _ in 0..<extentCount {
            if indexSize > 0 { _ = reader.uint(bytes: indexSize) }
            let offset = reader.uint(bytes: offsetSize)
            let length = reader.uint(bytes: lengthSize)
            extents.append(Extent(offset: offset, length: length))
        }
        result.append(Location(id: id, constructionMethod: construction, baseOffset: base, extents: extents))
    }
    version = 0
    return result
}

func payload(for location: Location, idat: Box?, data: Data) -> Data {
    var result = Data()
    for extent in location.extents {
        let start: UInt64
        if location.constructionMethod == 1, let idat {
            start = UInt64(idat.payloadStart) + location.baseOffset + extent.offset
        } else {
            start = location.baseOffset + extent.offset
        }
        result.append(data[Int(start)..<Int(start + extent.length)])
    }
    return result
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

func makeTemplate(donorPath: String, outputPath: String) throws {
    let donor = try Data(contentsOf: URL(fileURLWithPath: donorPath), options: .mappedIfSafe)
    let top = boxes(in: donor, from: 0, to: donor.count)
    guard top.contains(where: { $0.type == "ftyp" }),
          let meta = top.first(where: { $0.type == "meta" })
    else { throw CocoaError(.fileReadCorruptFile) }
    let children = boxes(in: donor, from: meta.payloadStart + 4, to: meta.end)
    guard let iloc = children.first(where: { $0.type == "iloc" }) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let idat = children.first(where: { $0.type == "idat" })
    let locations = parseLocations(iloc, data: donor)
    let iprp = children.first(where: { $0.type == "iprp" })!
    let iprpChildren = boxes(in: donor, from: iprp.payloadStart, to: iprp.end)
    let ipco = iprpChildren.first(where: { $0.type == "ipco" })!
    let properties = boxes(in: donor, from: ipco.payloadStart, to: ipco.end)
    let matteHVCC = donor[properties[37].start..<properties[37].end]
    let minimalIDs: [UInt32] = [65, 66, 141]

    var output = Data("SP3T0002".utf8)
    output.appendBE(UInt32(matteHVCC.count))
    output.append(matteHVCC)
    output.appendBE(UInt16(minimalIDs.count))
    for id in minimalIDs {
        guard let location = locations.first(where: { $0.id == id }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let bytes = payload(for: location, idat: idat, data: donor)
        output.appendBE(UInt16(id))
        output.appendBE(UInt32(bytes.count))
        output.append(bytes)
    }
    try output.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    print("wrote minimal \(output.count)-byte template to \(outputPath)")
}

func inspect(path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    let top = boxes(in: data, from: 0, to: data.count)
    print("\n=== \(URL(fileURLWithPath: path).lastPathComponent) (\(data.count) bytes) ===")
    print("top:", top.map { "\($0.type)(\($0.size))@\($0.start)" }.joined(separator: " "))
    guard let meta = top.first(where: { $0.type == "meta" }) else { return }
    let children = boxes(in: data, from: meta.payloadStart + 4, to: meta.end)
    print("meta:", children.map { "\($0.type)(\($0.size))" }.joined(separator: " "))

    let idat = children.first(where: { $0.type == "idat" })
    if let pitm = children.first(where: { $0.type == "pitm" }) {
        var (version, _, reader) = fullBox(pitm, data: data)
        let id = version == 0 ? UInt32(reader.u16()) : reader.u32()
        print("primary: \(id)")
        version = 0
    }

    let items = children.first(where: { $0.type == "iinf" }).map { parseItems($0, data: data) } ?? []
    let locations = children.first(where: { $0.type == "iloc" }).map { parseLocations($0, data: data) } ?? []
    print("items (\(items.count)):")
    for item in items {
        let location = locations.first(where: { $0.id == item.id })
        let extents = location?.extents.map { extent -> String in
            let absolute: UInt64
            if location?.constructionMethod == 1, let idat {
                absolute = UInt64(idat.payloadStart) + (location?.baseOffset ?? 0) + extent.offset
            } else {
                absolute = (location?.baseOffset ?? 0) + extent.offset
            }
            return "\(absolute)+\(extent.length)"
        }.joined(separator: ",") ?? "-"
        print(String(format: "  %3d  %-5@  %-28@  infe=%d+%d  cm=%d  %@  %@", item.id, item.type as NSString, item.name as NSString, item.boxStart, item.boxSize, location?.constructionMethod ?? 0, extents, item.contentType ?? ""))
    }

    if let iref = children.first(where: { $0.type == "iref" }) {
        let (version, _, _) = fullBox(iref, data: data)
        print("references:")
        for ref in boxes(in: data, from: iref.payloadStart + 4, to: iref.end) {
            var reader = Reader(data: data, offset: ref.payloadStart)
            let from = version == 0 ? UInt32(reader.u16()) : reader.u32()
            let count = Int(reader.u16())
            let targets = (0..<count).map { _ in version == 0 ? UInt32(reader.u16()) : reader.u32() }
            print("  \(ref.type) \(from) -> \(targets)")
        }
    }

    if let iprp = children.first(where: { $0.type == "iprp" }) {
        let iprpChildren = boxes(in: data, from: iprp.payloadStart, to: iprp.end)
        if let ipco = iprpChildren.first(where: { $0.type == "ipco" }) {
            print("properties:")
            for (index, property) in boxes(in: data, from: ipco.payloadStart, to: ipco.end).enumerated() {
                var suffix = ""
                if property.type == "auxC" {
                    var reader = Reader(data: data, offset: property.payloadStart + 4)
                    suffix = " " + reader.cString(limit: property.end)
                } else if property.type == "ispe" {
                    var reader = Reader(data: data, offset: property.payloadStart + 4)
                    suffix = " \(reader.u32())x\(reader.u32())"
                }
                print("  \(index + 1): \(property.type)(\(property.size))@\(property.start)\(suffix)")
            }
        }
        for ipma in iprpChildren.filter({ $0.type == "ipma" }) {
            var (version, flags, reader) = fullBox(ipma, data: data)
            let count = Int(reader.u32())
            print("associations: version=\(version) flags=\(flags) entries=\(count)")
            let wide = flags & 1 != 0
            for _ in 0..<count {
                let itemID = version < 1 ? UInt32(reader.u16()) : reader.u32()
                let associationCount = Int(reader.u8())
                let values: [(UInt32, Bool)] = (0..<associationCount).map { _ in
                    if wide {
                        let value = reader.u16()
                        return (UInt32(value & 0x7fff), value & 0x8000 != 0)
                    }
                    let value = reader.u8()
                    return (UInt32(value & 0x7f), value & 0x80 != 0)
                }
                print("  \(itemID): \(values.map { "\($0.0)\($0.1 ? "!" : "")" }.joined(separator: ","))")
            }
            version = 0
        }
    }
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--make-template" {
    do {
        try makeTemplate(donorPath: CommandLine.arguments[2], outputPath: CommandLine.arguments[3])
        exit(0)
    } catch {
        fputs("template error: \(error)\n", stderr)
        exit(1)
    }
}

guard CommandLine.arguments.count > 1 else {
    fputs("usage: swift Tools/heif-inspect.swift file.heic [...]\n", stderr)
    exit(2)
}

for path in CommandLine.arguments.dropFirst() {
    do { try inspect(path: path) }
    catch { fputs("\(path): \(error)\n", stderr) }
}
