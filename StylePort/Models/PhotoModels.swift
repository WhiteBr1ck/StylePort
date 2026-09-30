import Foundation
import UIKit

struct SelectedPhoto: Identifiable {
    var id: URL { sourceURL }

    let sourceURL: URL
    let assetIdentifier: String?
    let preview: UIImage
    let pixelSize: CGSize
    let fileName: String
}

struct ConvertedPhoto: Equatable {
    let outputURL: URL
    let replacedOriginal: Bool
    let filename: String
}

struct BatchConversionResult: Equatable {
    let convertedPhotos: [ConvertedPhoto]
    let failures: [String]

    var isFullySuccessful: Bool { failures.isEmpty }
}

enum ConversionPhase: Equatable {
    case idle
    case loading(current: Int, total: Int)
    case ready
    case converting(current: Int, total: Int)
    case saving(current: Int, total: Int)
    case completed(BatchConversionResult)
    case failed(String)
}
