import Foundation

nonisolated struct Styles3Transplanter: Sendable {
    private static let textureURI = "tag:apple.com,2026:photo:metadata:texture_styles"
    private static let matteURIs = [
        "tag:apple.com,2026:photo:aux:semanticnosematte",
        "tag:apple.com,2026:photo:aux:semanticskinmattev2",
        "tag:apple.com,2026:photo:aux:semanticnonfaceskinmatte",
        "tag:apple.com,2026:photo:aux:semanticlipsmatte",
        "tag:apple.com,2026:photo:aux:semanticteethmattev2",
        "tag:apple.com,2026:photo:aux:semanticpersonmatte",
        "tag:apple.com,2026:photo:aux:semanticglassesmattev2",
        "tag:apple.com,2026:photo:aux:semanticeyebrowsmatte",
        "tag:apple.com,2026:photo:aux:semantictattoomatte",
        "tag:apple.com,2026:photo:aux:semantichandsmatte",
        "tag:apple.com,2026:photo:aux:semanticearsmatte",
        "tag:apple.com,2026:photo:aux:semanticfaceskinmatte",
    ]

    func convert(source: Data, template: Styles3Template) throws -> Data {
        guard source.range(of: Data("tag:apple.com,2023:photo:metadata:styles".utf8)) != nil else {
            throw HEIFError.incompatible("This iPhone photo does not contain editable Photographic Styles data.")
        }
        if source.range(of: Data(Self.textureURI.utf8)) != nil {
            return source
        }
        guard let blackMatte = template.blackMatte,
              let matteXMP = template.matteXMP,
              let textureStyles = template.textureStyles
        else { throw HEIFError.malformed("Styles 3 template payloads are incomplete") }

        let top = try HEIFCodec.boxes(in: source, from: 0, to: source.count)
        guard let meta = top.first(where: { $0.type == "meta" }),
              let mdat = top.first(where: { $0.type == "mdat" })
        else { throw HEIFError.malformed("meta or mdat box is missing") }
        guard meta.end <= mdat.start else { throw HEIFError.unsupported("meta must precede mdat") }

        let children = try HEIFCodec.boxes(in: source, from: meta.payloadStart + 4, to: meta.end)
        guard let pitm = children.first(where: { $0.type == "pitm" }),
              let iinf = children.first(where: { $0.type == "iinf" }),
              let iref = children.first(where: { $0.type == "iref" }),
              let iprp = children.first(where: { $0.type == "iprp" }),
              let iloc = children.first(where: { $0.type == "iloc" })
        else { throw HEIFError.malformed("required item graph boxes are missing") }

        let items = try HEIFCodec.items(in: iinf, data: source)
        let nextID = (items.map(\.id).max() ?? 0) + 1
        guard nextID + 24 <= UInt32(UInt16.max) else { throw HEIFError.unsupported("item identifiers exceed 16 bits") }
        let matteIDs = (0..<12).map { nextID + UInt32($0 * 2) }
        let xmpIDs = matteIDs.map { $0 + 1 }
        let textureID = nextID + 24
        let primaryID = try primaryItemID(pitm, source: source)
        guard let tmapID = items.first(where: { $0.type == "tmap" })?.id else {
            throw HEIFError.incompatible("This photo does not contain the required HDR tone-map item.")
        }

        let newIINF = try buildIINF(iinf, source: source, matteIDs: matteIDs, xmpIDs: xmpIDs, textureID: textureID)
        let (newIPRP, propertyIndexes) = try buildIPRP(iprp, source: source, template: template, matteIDs: matteIDs)
        let newIREF = try buildIREF(iref, source: source, matteIDs: matteIDs, xmpIDs: xmpIDs, textureID: textureID, primaryID: primaryID, tmapID: tmapID)

        var appended = Data()
        var payloadLocations: [(UInt32, Int, Int)] = []
        for index in 0..<12 {
            let matteStart = appended.count
            appended.append(blackMatte)
            payloadLocations.append((matteIDs[index], matteStart, blackMatte.count))
            let xmpStart = appended.count
            appended.append(matteXMP)
            payloadLocations.append((xmpIDs[index], xmpStart, matteXMP.count))
        }
        let textureStart = appended.count
        appended.append(textureStyles)
        payloadLocations.append((textureID, textureStart, textureStyles.count))

        let (ilocLayout, oldLocations) = try HEIFCodec.locations(in: iloc, data: source)
        let placeholderLocations = oldLocations + payloadLocations.map {
            HEIFLocation(
                itemID: $0.0,
                constructionMethod: 0,
                dataReferenceIndex: 0,
                baseOffset: 0,
                extents: [HEIFExtent(index: 0, offset: 0, length: UInt64($0.2))]
            )
        }
        let placeholderILOC = try HEIFCodec.serializeLocations(placeholderLocations, layout: ilocLayout)
        let placeholderMeta = try rebuildMeta(
            source: source,
            meta: meta,
            children: children,
            replacements: ["iinf": newIINF, "iref": newIREF, "iprp": newIPRP, "iloc": placeholderILOC]
        )
        let delta = placeholderMeta.count - meta.size
        guard delta >= 0 else { throw HEIFError.malformed("unexpected negative metadata growth") }

        var shifted = try oldLocations.map { try shiftedLocation($0, by: UInt64(delta)) }
        let appendBase = UInt64(mdat.end + delta)
        shifted.append(contentsOf: payloadLocations.map {
            HEIFLocation(
                itemID: $0.0,
                constructionMethod: 0,
                dataReferenceIndex: 0,
                baseOffset: 0,
                extents: [HEIFExtent(index: 0, offset: appendBase + UInt64($0.1), length: UInt64($0.2))]
            )
        })
        let newILOC = try HEIFCodec.serializeLocations(shifted, layout: ilocLayout)
        let newMeta = try rebuildMeta(
            source: source,
            meta: meta,
            children: children,
            replacements: ["iinf": newIINF, "iref": newIREF, "iprp": newIPRP, "iloc": newILOC]
        )
        guard newMeta.count - meta.size == delta else { throw HEIFError.malformed("metadata size changed between passes") }

        let newMDAT = try growMDAT(mdat, source: source, appended: appended)
        var output = Data(capacity: source.count + delta + appended.count)
        for box in top {
            switch box.type {
            case "meta": output.append(newMeta)
            case "mdat": output.append(newMDAT)
            default: output.append(HEIFCodec.raw(box, in: source))
            }
        }
        guard output.range(of: Data(Self.textureURI.utf8)) != nil,
              output.range(of: Data(Self.matteURIs.last!.utf8)) != nil
        else { throw HEIFError.malformed("Styles 3 contract validation failed") }
        _ = propertyIndexes
        return output
    }

    private func primaryItemID(_ pitm: HEIFBox, source: Data) throws -> UInt32 {
        let (version, _, initialReader) = try HEIFCodec.fullBox(pitm, in: source)
        var reader = initialReader
        return version == 0 ? UInt32(try reader.readUInt16()) : try reader.readUInt32()
    }

    private func buildIINF(
        _ iinf: HEIFBox,
        source: Data,
        matteIDs: [UInt32],
        xmpIDs: [UInt32],
        textureID: UInt32
    ) throws -> Data {
        let (version, flags, initialReader) = try HEIFCodec.fullBox(iinf, in: source)
        var reader = initialReader
        let oldCount = version == 0 ? Int(try reader.readUInt16()) : Int(try reader.readUInt32())
        var payload = Data([version])
        payload.appendUInt24(flags)
        let newCount = oldCount + 25
        if version == 0 {
            guard newCount <= Int(UInt16.max) else { throw HEIFError.unsupported("too many iinf entries") }
            payload.appendBE(UInt16(newCount))
        } else {
            payload.appendBE(UInt32(newCount))
        }
        payload.append(source[reader.offset..<iinf.end])
        for index in 0..<12 {
            payload.append(try makeINFE(id: matteIDs[index], type: "hvc1", name: "", trailing: Data()))
            var mime = Data("application/rdf+xml".utf8)
            mime.append(0)
            mime.append(0)
            payload.append(try makeINFE(id: xmpIDs[index], type: "mime", name: "", trailing: mime))
        }
        var uri = Data(Self.textureURI.utf8)
        uri.append(0)
        payload.append(try makeINFE(id: textureID, type: "uri ", name: "metadata", trailing: uri))
        return try HEIFCodec.makeBox(type: "iinf", payload: payload)
    }

    private func makeINFE(id: UInt32, type: String, name: String, trailing: Data) throws -> Data {
        guard id <= UInt32(UInt16.max) else { throw HEIFError.unsupported("item id exceeds 16 bits") }
        var payload = Data([2, 0, 0, 1])
        payload.appendBE(UInt16(id))
        payload.appendBE(UInt16(0))
        payload.append(contentsOf: type.utf8)
        payload.append(contentsOf: name.utf8)
        payload.append(0)
        payload.append(trailing)
        return try HEIFCodec.makeBox(type: "infe", payload: payload)
    }

    private struct PropertyIndexes {
        let ispe: UInt32
        let monoPixi: UInt32
        let auxC: [UInt32]
        let hvcc: UInt32
        let rotation: UInt32
    }

    private func buildIPRP(
        _ iprp: HEIFBox,
        source: Data,
        template: Styles3Template,
        matteIDs: [UInt32]
    ) throws -> (Data, PropertyIndexes) {
        let children = try HEIFCodec.boxes(in: source, from: iprp.payloadStart, to: iprp.end)
        guard let ipco = children.first(where: { $0.type == "ipco" }),
              let ipma = children.first(where: { $0.type == "ipma" })
        else { throw HEIFError.malformed("ipco or ipma is missing") }
        let oldProperties = try HEIFCodec.boxes(in: source, from: ipco.payloadStart, to: ipco.end)
        guard let monoIndex = oldProperties.firstIndex(where: { property in
            guard property.type == "pixi", property.size == 14 else { return false }
            return source[property.payloadStart + 4] == 1 && source[property.payloadStart + 5] == 8
        }).map({ UInt32($0 + 1) }) else {
            throw HEIFError.incompatible("The photo does not contain a compatible monochrome pixel property.")
        }
        guard let rotationIndex = oldProperties.firstIndex(where: { $0.type == "irot" }).map({ UInt32($0 + 1) }) else {
            throw HEIFError.incompatible("The photo does not contain an orientation property.")
        }

        var propertyPayload = source[ipco.payloadStart..<ipco.end]
        var nextIndex = UInt32(oldProperties.count + 1)
        propertyPayload.append(try makeISPE(width: 768, height: 576))
        let ispeIndex = nextIndex
        nextIndex += 1
        var auxIndexes: [UInt32] = []
        for uri in Self.matteURIs {
            propertyPayload.append(try makeAuxC(uri: uri))
            auxIndexes.append(nextIndex)
            nextIndex += 1
        }
        propertyPayload.append(template.matteHVCC)
        let hvccIndex = nextIndex
        let indexes = PropertyIndexes(ispe: ispeIndex, monoPixi: monoIndex, auxC: auxIndexes, hvcc: hvccIndex, rotation: rotationIndex)
        let newIPCO = try HEIFCodec.makeBox(type: "ipco", payload: propertyPayload)
        let newIPMA = try appendIPMA(ipma, source: source, matteIDs: matteIDs, indexes: indexes)

        var payload = Data()
        for child in children {
            if child.type == "ipco" { payload.append(newIPCO) }
            else if child.type == "ipma" { payload.append(newIPMA) }
            else { payload.append(HEIFCodec.raw(child, in: source)) }
        }
        return (try HEIFCodec.makeBox(type: "iprp", payload: payload), indexes)
    }

    private func appendIPMA(
        _ ipma: HEIFBox,
        source: Data,
        matteIDs: [UInt32],
        indexes: PropertyIndexes
    ) throws -> Data {
        let (version, flags, initialReader) = try HEIFCodec.fullBox(ipma, in: source)
        guard flags & 1 == 0 else { throw HEIFError.unsupported("wide ipma associations are not yet supported") }
        var reader = initialReader
        let oldCount = try reader.readUInt32()
        var payload = Data([version])
        payload.appendUInt24(flags)
        payload.appendBE(oldCount + UInt32(matteIDs.count))
        payload.append(source[reader.offset..<ipma.end])
        for (offset, itemID) in matteIDs.enumerated() {
            if version < 1 {
                payload.appendBE(UInt16(itemID))
            } else {
                payload.appendBE(itemID)
            }
            let associations: [(UInt32, Bool)] = [
                (indexes.ispe, false),
                (indexes.monoPixi, false),
                (indexes.auxC[offset], true),
                (indexes.hvcc, true),
                (indexes.rotation, true),
            ]
            payload.append(UInt8(associations.count))
            for (index, essential) in associations {
                guard index <= 0x7f else { throw HEIFError.unsupported("ipma property index exceeds 7 bits") }
                payload.append(UInt8(index) | (essential ? 0x80 : 0))
            }
        }
        return try HEIFCodec.makeBox(type: "ipma", payload: payload)
    }

    private func makeISPE(width: UInt32, height: UInt32) throws -> Data {
        var payload = Data(repeating: 0, count: 4)
        payload.appendBE(width)
        payload.appendBE(height)
        return try HEIFCodec.makeBox(type: "ispe", payload: payload)
    }

    private func makeAuxC(uri: String) throws -> Data {
        var payload = Data(repeating: 0, count: 4)
        payload.append(contentsOf: uri.utf8)
        payload.append(0)
        return try HEIFCodec.makeBox(type: "auxC", payload: payload)
    }

    private func buildIREF(
        _ iref: HEIFBox,
        source: Data,
        matteIDs: [UInt32],
        xmpIDs: [UInt32],
        textureID: UInt32,
        primaryID: UInt32,
        tmapID: UInt32
    ) throws -> Data {
        let (version, flags, _) = try HEIFCodec.fullBox(iref, in: source)
        guard version == 0 else { throw HEIFError.unsupported("32-bit iref identifiers are not supported") }
        var payload = Data([version])
        payload.appendUInt24(flags)
        payload.append(source[(iref.payloadStart + 4)..<iref.end])
        for index in 0..<12 {
            payload.append(try makeReference(type: "auxl", from: matteIDs[index], to: [primaryID, tmapID]))
            payload.append(try makeReference(type: "cdsc", from: xmpIDs[index], to: [matteIDs[index]]))
        }
        payload.append(try makeReference(type: "cdsc", from: textureID, to: [primaryID, tmapID]))
        return try HEIFCodec.makeBox(type: "iref", payload: payload)
    }

    private func makeReference(type: String, from: UInt32, to: [UInt32]) throws -> Data {
        guard from <= UInt32(UInt16.max), to.allSatisfy({ $0 <= UInt32(UInt16.max) }) else {
            throw HEIFError.unsupported("reference id exceeds 16 bits")
        }
        var payload = Data()
        payload.appendBE(UInt16(from))
        payload.appendBE(UInt16(to.count))
        for target in to { payload.appendBE(UInt16(target)) }
        return try HEIFCodec.makeBox(type: type, payload: payload)
    }

    private func shiftedLocation(_ location: HEIFLocation, by delta: UInt64) throws -> HEIFLocation {
        guard location.constructionMethod == 0 else { return location }
        var copy = location
        if copy.baseOffset > 0 {
            let (value, overflow) = copy.baseOffset.addingReportingOverflow(delta)
            guard !overflow else { throw HEIFError.unsupported("base offset overflow") }
            copy.baseOffset = value
        } else {
            copy.extents = try copy.extents.map { extent in
                var extent = extent
                let (value, overflow) = extent.offset.addingReportingOverflow(delta)
                guard !overflow else { throw HEIFError.unsupported("extent offset overflow") }
                extent.offset = value
                return extent
            }
        }
        return copy
    }

    private func rebuildMeta(
        source: Data,
        meta: HEIFBox,
        children: [HEIFBox],
        replacements: [String: Data]
    ) throws -> Data {
        var payload = source[meta.payloadStart..<(meta.payloadStart + 4)]
        for child in children {
            payload.append(replacements[child.type] ?? HEIFCodec.raw(child, in: source))
        }
        return try HEIFCodec.makeBox(type: "meta", payload: payload)
    }

    private func growMDAT(_ mdat: HEIFBox, source: Data, appended: Data) throws -> Data {
        var payload = source[mdat.payloadStart..<mdat.end]
        payload.append(appended)
        if mdat.headerSize == 16 {
            var result = Data()
            result.appendBE(UInt32(1))
            result.append(contentsOf: "mdat".utf8)
            result.appendBE(UInt64(payload.count + 16))
            result.append(payload)
            return result
        }
        return try HEIFCodec.makeBox(type: "mdat", payload: payload)
    }
}
