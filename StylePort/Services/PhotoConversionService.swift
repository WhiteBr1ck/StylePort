import Foundation
import ImageIO

nonisolated enum PhotoConversionError: LocalizedError {
    case invalidOutput

    var errorDescription: String? {
        "The converted HEIC could not be decoded or did not contain the complete Styles 3 contract."
    }
}

nonisolated struct PhotoConversionService: Sendable {
    @concurrent
    func convert(sourceURL: URL, originalFilename: String? = nil) async throws -> URL {
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let template = try Styles3Template.bundled()
        let converted = try Styles3Transplanter().convert(source: source, template: template)
        guard let imageSource = CGImageSourceCreateWithData(converted as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0,
              converted.range(of: Data("tag:apple.com,2026:photo:metadata:texture_styles".utf8)) != nil,
              converted.range(of: Data("tag:apple.com,2026:photo:aux:semanticfaceskinmatte".utf8)) != nil
        else { throw PhotoConversionError.invalidOutput }

        let directory = try Self.outputDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(Self.convertedFilename(from: originalFilename))
        try converted.write(to: outputURL, options: .atomic)
        return outputURL
    }

    @concurrent
    static func eligibility(of sourceURL: URL) async throws -> PhotoEligibility {
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        if source.range(of: Data("tag:apple.com,2026:photo:metadata:texture_styles".utf8)) != nil {
            return .alreadyConverted
        }
        guard source.range(of: Data("tag:apple.com,2023:photo:metadata:styles".utf8)) != nil else {
            return .incompatible
        }
        return .convertible
    }

    static func convertedFilename(from originalFilename: String?) -> String {
        let fallback = "Photo.HEIC"
        let input = (originalFilename?.isEmpty == false ? originalFilename : fallback) ?? fallback
        let url = URL(fileURLWithPath: input)
        var stem = url.deletingPathExtension().lastPathComponent
        if stem.isEmpty { stem = "Photo" }
        if stem.count > 54 { stem = String(stem.prefix(54)) }
        return "\(stem)_GP.HEIC"
    }

    private static func outputDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
