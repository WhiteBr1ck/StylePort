@preconcurrency import Photos
import SwiftUI

struct LibraryThumbnailView: View {
    let assetIdentifier: String?
    var cornerRadius: CGFloat = 14

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.tertiary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: assetIdentifier) {
            image = await thumbnail()
        }
    }

    private func thumbnail() async -> UIImage? {
        guard let assetIdentifier,
              let asset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [assetIdentifier],
                  options: nil
              ).firstObject
        else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 520, height: 520),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                guard !isDegraded else { return }
                continuation.resume(returning: image)
            }
        }
    }
}
