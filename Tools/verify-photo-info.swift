import Foundation

@main
struct VerifyPhotoInfo {
  static func main() throws {
    guard CommandLine.arguments.count == 4 else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let donor = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let template = try Styles3Template(
      data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    let converted = try Styles3Transplanter().convert(source: source, template: template)
    let before = try PhotoMetadataReader.read(data: source, filename: "Original.HEIC")
    let after = try PhotoMetadataReader.read(data: converted, filename: "Copy.HEIC")
    let native = try PhotoMetadataReader.read(data: donor, filename: "Native.HEIC")
    let oldStyle = try require(before.style)
    let newStyle = try require(after.style)
    let nativeStyle = try require(native.style)
    print(
      "Container detection: old \(oldStyle.hasStyles)/\(oldStyle.hasTexture), new \(newStyle.hasStyles)/\(newStyle.hasTexture) mattes \(newStyle.newMatteCount), native \(nativeStyle.hasStyles)/\(nativeStyle.hasTexture) mattes \(nativeStyle.newMatteCount)."
    )
    precondition(oldStyle.hasStyles && !oldStyle.hasTexture)
    precondition(newStyle.hasStyles && newStyle.hasTexture && newStyle.newMatteCount == 12)
    precondition(nativeStyle.hasTexture && nativeStyle.newMatteCount == 12)
    precondition(
      oldStyle.primaryImageDigest != nil
        && oldStyle.primaryImageDigest == newStyle.primaryImageDigest)
    precondition(before.rawFields == after.rawFields)
    let retainedFields = oldStyle.rawFields.filter { $0.id.hasPrefix(PhotoStyleMetadata.stylesURI) }
    precondition(
      retainedFields == newStyle.rawFields.filter { $0.id.hasPrefix(PhotoStyleMetadata.stylesURI) })
    precondition(!after.differences(from: before).isEmpty)
    print(
      "PASS: original/native style detection, 12 added matte types, unchanged primary encoding, EXIF and original style payload, visible metadata differences."
    )
    print(
      "Detected style sizes: original \(oldStyle.payloadSizes.values.sorted()); converted \(newStyle.payloadSizes.values.sorted()); native \(nativeStyle.payloadSizes.values.sorted())."
    )
  }

  static func require<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.fileReadCorruptFile) }
    return value
  }
}
