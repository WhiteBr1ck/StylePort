import CoreGraphics
import Foundation

struct LibraryPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

struct PhotoAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
    let coverAssetIdentifier: String?
}

enum PhotoEligibility: String, Sendable {
    case convertible
    case alreadyConverted
    case incompatible
}

enum PhotoLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case needsConversion
    case converted

    var id: Self { self }
}

enum PhotoLibrarySort: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: Self { self }
}

struct BatchConversionSummary: Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let skipped: Int
    let failed: Int
    let failureMessages: [String]

    static let empty = BatchConversionSummary(
        total: 0,
        succeeded: 0,
        skipped: 0,
        failed: 0,
        failureMessages: []
    )
}

enum BatchConversionPhase: Equatable {
    case idle
    case preparing(current: Int, total: Int)
    case converting(current: Int, total: Int)
    case saving(current: Int, total: Int)
    case completed(BatchConversionSummary)
}

struct ConversionReport: Identifiable {
    let id = UUID()
    let summary: BatchConversionSummary
}

struct ExternalPhotoInput: Sendable {
    let url: URL
    let originalFilename: String
    var pairedVideoURL: URL? = nil
}
