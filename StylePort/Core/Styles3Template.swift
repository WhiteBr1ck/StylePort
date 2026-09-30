import Foundation

nonisolated struct Styles3Template: Sendable {
    let matteHVCC: Data
    let payloads: [UInt32: Data]

    init(data: Data) throws {
        guard data.count >= 14, data.prefix(8) == Data("SP3T0002".utf8) else {
            throw HEIFError.malformed("invalid Styles 3 template")
        }
        var reader = HEIFReader(data: data, offset: 8)
        let hvccLength = Int(try reader.readUInt32())
        guard reader.offset + hvccLength <= data.count else { throw HEIFError.malformed("truncated template hvcC") }
        matteHVCC = data[reader.offset..<(reader.offset + hvccLength)]
        reader.offset += hvccLength
        let count = Int(try reader.readUInt16())
        var payloads: [UInt32: Data] = [:]
        for _ in 0..<count {
            let id = UInt32(try reader.readUInt16())
            let length = Int(try reader.readUInt32())
            guard reader.offset + length <= data.count else { throw HEIFError.malformed("truncated template payload") }
            payloads[id] = data[reader.offset..<(reader.offset + length)]
            reader.offset += length
        }
        self.payloads = payloads
    }

    nonisolated static func bundled() throws -> Styles3Template {
        guard let url = Bundle.main.url(forResource: "Styles3Template", withExtension: "bin") else {
            throw HEIFError.malformed("Styles 3 template resource is missing")
        }
        return try Styles3Template(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    var blackMatte: Data? { payloads[65] }
    var matteXMP: Data? { payloads[66] }
    var textureStyles: Data? { payloads[141] }
}
