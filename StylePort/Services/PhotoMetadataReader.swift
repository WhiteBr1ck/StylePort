import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PhotoMetadataField: Identifiable, Equatable, Sendable {
  let id: String
  let value: String
}

nonisolated struct PhotoStyleMetadata: Sendable {
  static let stylesURI = "tag:apple.com,2023:photo:metadata:styles"
  static let textureURI = "tag:apple.com,2026:photo:metadata:texture_styles"
  let payloadSizes: [String: Int]
  let auxiliaryTypes: [String]
  let rawFields: [PhotoMetadataField]
  let primaryImageDigest: String?
  var hasStyles: Bool { payloadSizes[Self.stylesURI] != nil }
  var hasTexture: Bool { payloadSizes[Self.textureURI] != nil }
  var newMatteCount: Int {
    auxiliaryTypes.filter { $0.hasPrefix("tag:apple.com,2026:photo:aux:semantic") }.count
  }
}

nonisolated struct PhotoMetadata: Sendable {
  let filename: String
  let byteCount: Int
  let format: String
  let basics: [PhotoMetadataField]
  let rawFields: [PhotoMetadataField]
  let style: PhotoStyleMetadata?

  /// Compare actual stored values, not interpreted private Apple keys.
  func differences(from other: PhotoMetadata) -> [PhotoMetadataField] {
    let left = Dictionary(
      other.comparisonFields.map { ($0.id, $0.value) }, uniquingKeysWith: { _, latest in latest })
    let right = Dictionary(
      comparisonFields.map { ($0.id, $0.value) }, uniquingKeysWith: { _, latest in latest })
    return Set(left.keys).union(right.keys).sorted().compactMap { key in
      guard left[key] != right[key] else { return nil }
      return PhotoMetadataField(id: key, value: "\(left[key] ?? "—") → \(right[key] ?? "—")")
    }
  }

  private var comparisonFields: [PhotoMetadataField] {
    var result = rawFields
    if let style {
      result += style.payloadSizes.sorted { $0.key < $1.key }.map {
        PhotoMetadataField(id: $0.key, value: "\($0.value) bytes")
      }
      result += style.auxiliaryTypes.map { PhotoMetadataField(id: $0, value: "present") }
      result += style.rawFields
    }
    return result
  }
}

nonisolated enum PhotoMetadataReader {
  @concurrent
  static func read(url: URL, filename: String) async throws -> PhotoMetadata {
    try Task.checkCancellation()
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return try read(data: data, filename: filename)
  }

  static func read(data: Data, filename: String) throws -> PhotoMetadata {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { throw CocoaError(.fileReadCorruptFile) }
    let identifier = CGImageSourceGetType(source).map { $0 as String } ?? ""
    let format = UTType(identifier)?.preferredFilenameExtension?.uppercased() ?? identifier
    let exif = properties["{Exif}"] as? [String: Any] ?? [:]
    let tiff = properties["{TIFF}"] as? [String: Any] ?? [:]
    var basics: [PhotoMetadataField] = []
    func add(_ key: String, _ value: Any?) {
      if let value { basics.append(PhotoMetadataField(id: key, value: display(value))) }
    }
    if let width = properties["PixelWidth"], let height = properties["PixelHeight"] {
      add("dimensions", "\(display(width)) × \(display(height)) px")
    }
    add("camera", tiff["Model"])
    add("make", tiff["Make"])
    add("lens", exif["LensModel"])
    add("date", exif["DateTimeOriginal"] ?? tiff["DateTime"])
    add("timeZone", exif["OffsetTimeOriginal"])
    if let value = exif["FNumber"] as? NSNumber {
      add("aperture", String(format: "ƒ/%.2f", value.doubleValue))
    }
    if let value = exif["ExposureTime"] as? NSNumber, value.doubleValue > 0 {
      let seconds = value.doubleValue
      add(
        "exposure",
        seconds < 1 ? String(format: "1/%.0f s", 1 / seconds) : String(format: "%.2f s", seconds))
    }
    add("iso", exif["ISOSpeedRatings"])
    if let value = exif["FocalLength"] { add("focalLength", "\(display(value)) mm") }
    if let value = exif["FocalLenIn35mmFilm"] {
      add("equivalentFocalLength", "\(display(value)) mm")
    }
    if let value = exif["ExposureBiasValue"] { add("exposureBias", "\(display(value)) EV") }
    add("profile", properties["ProfileName"])
    add("colorModel", properties["ColorModel"])
    if let value = properties["Depth"] { add("depth", "\(display(value)) bit") }
    add("orientation", properties["Orientation"])
    add("software", tiff["Software"])
    add("gps", (properties["{GPS}"] as? [String: Any])?.isEmpty == false ? "present" : "absent")
    return PhotoMetadata(
      filename: filename, byteCount: data.count, format: format,
      basics: basics, rawFields: flatten(properties, prefix: "ImageIO"),
      style: try? readStyleContainer(data))
  }

  static func readStyleContainer(_ data: Data) throws -> PhotoStyleMetadata {
    let top = try HEIFCodec.boxes(in: data, from: 0, to: data.count)
    guard let meta = top.first(where: { $0.type == "meta" }) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let children = try HEIFCodec.boxes(in: data, from: meta.payloadStart + 4, to: meta.end)
    guard let iinf = children.first(where: { $0.type == "iinf" }),
      let iloc = children.first(where: { $0.type == "iloc" })
    else { throw CocoaError(.fileReadCorruptFile) }
    let items = try HEIFCodec.items(in: iinf, data: data)
    let (_, locations) = try HEIFCodec.locations(in: iloc, data: data)
    let idat = children.first(where: { $0.type == "idat" })
    var sizes: [String: Int] = [:]
    var fields: [PhotoMetadataField] = []
    let (_, _, iinfReader) = try HEIFCodec.fullBox(iinf, in: data)
    let entryStart = iinfReader.offset + (data[iinf.payloadStart] == 0 ? 2 : 4)
    for entry in try HEIFCodec.boxes(in: data, from: entryStart, to: iinf.end)
    where entry.type == "infe" {
      let (version, _, initial) = try HEIFCodec.fullBox(entry, in: data)
      var reader = initial
      guard version >= 2 else { continue }
      let id = version == 2 ? UInt32(try reader.readUInt16()) : try reader.readUInt32()
      _ = try reader.readUInt16()
      guard try reader.readFourCC() == "uri " else { continue }
      _ = try cString(data, offset: &reader.offset, end: entry.end)
      let uri = try cString(data, offset: &reader.offset, end: entry.end)
      guard uri == PhotoStyleMetadata.stylesURI || uri == PhotoStyleMetadata.textureURI,
        let location = locations.first(where: { $0.itemID == id })
      else { continue }
      let payload = try itemPayload(location, idat: idat, data: data)
      sizes[uri] = payload.count
      if let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) {
        fields += flatten(plist, prefix: uri)
      }
    }
    var auxiliary: [String] = []
    if let iprp = children.first(where: { $0.type == "iprp" }),
      let ipco = try HEIFCodec.boxes(in: data, from: iprp.payloadStart, to: iprp.end).first(where: {
        $0.type == "ipco"
      })
    {
      for property in try HEIFCodec.boxes(in: data, from: ipco.payloadStart, to: ipco.end)
      where property.type == "auxC" {
        var offset = property.payloadStart + 4
        auxiliary.append(try cString(data, offset: &offset, end: property.end))
      }
    }
    // Follow the primary image's dimg graph. Added semantic mattes are not part of this digest.
    var primaryDigest: String?
    if let pitm = children.first(where: { $0.type == "pitm" }) {
      let (version, _, initial) = try HEIFCodec.fullBox(pitm, in: data)
      var reader = initial
      let primaryID = version == 0 ? UInt32(try reader.readUInt16()) : try reader.readUInt32()
      var graph: [UInt32: [UInt32]] = [:]
      if let iref = children.first(where: { $0.type == "iref" }) {
        let (refVersion, _, _) = try HEIFCodec.fullBox(iref, in: data)
        for ref in try HEIFCodec.boxes(in: data, from: iref.payloadStart + 4, to: iref.end)
        where ref.type == "dimg" {
          var r = HEIFReader(data: data, offset: ref.payloadStart)
          let from = refVersion == 0 ? UInt32(try r.readUInt16()) : try r.readUInt32()
          let count = Int(try r.readUInt16())
          graph[from] = try (0..<count).map { _ in
            refVersion == 0 ? UInt32(try r.readUInt16()) : try r.readUInt32()
          }
        }
      }
      var visited: Set<UInt32> = []
      var hasher = SHA256()
      func hashItem(_ id: UInt32) throws {
        guard visited.insert(id).inserted else { return }
        guard let item = items.first(where: { $0.id == id }),
          let location = locations.first(where: { $0.itemID == id })
        else { throw CocoaError(.fileReadCorruptFile) }
        hasher.update(data: Data(item.type.utf8))
        hasher.update(data: try itemPayload(location, idat: idat, data: data))
        for child in graph[id] ?? [] { try hashItem(child) }
      }
      try hashItem(primaryID)
      primaryDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    return PhotoStyleMetadata(
      payloadSizes: sizes, auxiliaryTypes: Array(Set(auxiliary)).sorted(),
      rawFields: fields, primaryImageDigest: primaryDigest)
  }

  private static func cString(_ data: Data, offset: inout Int, end: Int) throws -> String {
    guard offset >= 0, offset < end, end <= data.count,
      let terminator = data[offset..<end].firstIndex(of: 0),
      let string = String(data: data[offset..<terminator], encoding: .utf8)
    else { throw CocoaError(.fileReadCorruptFile) }
    offset = terminator + 1
    return string
  }

  private static func itemPayload(_ location: HEIFLocation, idat: HEIFBox?, data: Data) throws
    -> Data
  {
    guard location.dataReferenceIndex == 0, location.constructionMethod <= 1 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let base: UInt64
    if location.constructionMethod == 1 {
      guard let idat else { throw CocoaError(.fileReadCorruptFile) }
      base = UInt64(idat.payloadStart)
    } else {
      base = 0
    }
    var result = Data()
    for extent in location.extents {
      let (first, overflow1) = base.addingReportingOverflow(location.baseOffset)
      let (start, overflow2) = first.addingReportingOverflow(extent.offset)
      let (end, overflow3) = start.addingReportingOverflow(extent.length)
      guard !overflow1, !overflow2, !overflow3, end <= UInt64(data.count),
        location.constructionMethod == 0 || end <= UInt64(idat?.end ?? 0)
      else { throw CocoaError(.fileReadCorruptFile) }
      result.append(data[Int(start)..<Int(end)])
    }
    return result
  }

  private static func flatten(_ value: Any, prefix: String) -> [PhotoMetadataField] {
    if let dictionary = value as? [String: Any] {
      return dictionary.keys.sorted().flatMap { key -> [PhotoMetadataField] in
        guard let child = dictionary[key] else { return [] }
        return flatten(child, prefix: "\(prefix).\(key)")
      }
    }
    if let array = value as? [Any], array.contains(where: { $0 is [String: Any] }) {
      return array.enumerated().flatMap { flatten($0.element, prefix: "\(prefix)[\($0.offset)]") }
    }
    return [PhotoMetadataField(id: prefix, value: display(value))]
  }

  private static func display(_ value: Any) -> String {
    if let data = value as? Data {
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return "\(data.count) bytes · SHA256 \(digest)"
    }
    if let number = value as? NSNumber {
      return String(format: "%.8g", number.doubleValue)
    }
    if let array = value as? [Any] { return array.map(display).joined(separator: ", ") }
    return String(describing: value)
  }
}
