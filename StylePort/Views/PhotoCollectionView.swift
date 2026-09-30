@preconcurrency import Photos
import SwiftUI
import UIKit

struct PhotoCollectionView: UIViewRepresentable {
    let photos: [LibraryPhoto]
    @Binding var selection: Set<String>
    @Binding var isSelecting: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, isSelecting: $isSelecting)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 2
        layout.minimumInteritemSpacing = 2
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(PhotoThumbnailCell.self, forCellWithReuseIdentifier: PhotoThumbnailCell.reuseIdentifier)
        context.coordinator.collectionView = collectionView
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        let newIdentifiers = photos.map(\.id)
        if context.coordinator.photoIdentifiers != newIdentifiers {
            context.coordinator.photos = photos
            context.coordinator.photoIdentifiers = newIdentifiers
            collectionView.reloadData()
        }
        if context.coordinator.isSelectionMode != isSelecting {
            context.coordinator.isSelectionMode = isSelecting
            collectionView.reloadData()
        }
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            guard photos.indices.contains(indexPath.item),
                  !selection.contains(photos[indexPath.item].id)
            else { continue }
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        for (index, photo) in photos.enumerated() where selection.contains(photo.id) {
            collectionView.selectItem(at: IndexPath(item: index, section: 0), animated: false, scrollPosition: [])
        }
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var photos: [LibraryPhoto] = []
        var photoIdentifiers: [String] = []
        var isSelectionMode = false
        weak var collectionView: UICollectionView?
        private var selection: Binding<Set<String>>
        private var isSelecting: Binding<Bool>
        private let imageManager = PHCachingImageManager()

        init(selection: Binding<Set<String>>, isSelecting: Binding<Bool>) {
            self.selection = selection
            self.isSelecting = isSelecting
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            photos.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PhotoThumbnailCell.reuseIdentifier,
                for: indexPath
            ) as! PhotoThumbnailCell
            let photo = photos[indexPath.item]
            cell.representedIdentifier = photo.id
            cell.setSelectionMode(isSelectionMode)
            cell.setSelected(selection.wrappedValue.contains(photo.id), animated: false)

            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [photo.id],
                options: nil
            ).firstObject else { return cell }
            let scale = collectionView.traitCollection.displayScale
            let side = max(120, (collectionView.bounds.width / 4) * scale)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            cell.imageRequestID = imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { [weak cell] image, _ in
                guard cell?.representedIdentifier == photo.id else { return }
                cell?.setImage(image)
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            let side = floor((collectionView.bounds.width - 6) / 4)
            return CGSize(width: side, height: side)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard photos.indices.contains(indexPath.item) else { return }
            if !isSelecting.wrappedValue { isSelecting.wrappedValue = true }
            selection.wrappedValue.insert(photos[indexPath.item].id)
            (collectionView.cellForItem(at: indexPath) as? PhotoThumbnailCell)?.setSelected(true, animated: true)
        }

        func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
            isSelecting.wrappedValue
        }

        func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
            guard photos.indices.contains(indexPath.item) else { return }
            selection.wrappedValue.remove(photos[indexPath.item].id)
            (collectionView.cellForItem(at: indexPath) as? PhotoThumbnailCell)?.setSelected(false, animated: true)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) -> Bool {
            true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didBeginMultipleSelectionInteractionAt indexPath: IndexPath
        ) {
            isSelecting.wrappedValue = true
        }
    }
}

@MainActor
private final class PhotoThumbnailCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoThumbnailCell"

    var representedIdentifier: String?
    var imageRequestID = PHInvalidImageRequestID

    private let imageView = UIImageView()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private var isSelectionMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .tertiarySystemFill
        checkmark.tintColor = .systemBlue
        checkmark.backgroundColor = .white
        checkmark.layer.cornerRadius = 11
        checkmark.isHidden = true
        contentView.addSubview(imageView)
        contentView.addSubview(checkmark)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            checkmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            checkmark.widthAnchor.constraint(equalToConstant: 22),
            checkmark.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Photo"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedIdentifier = nil
        imageView.image = nil
        checkmark.isHidden = true
        accessibilityTraits.remove(.selected)
    }

    func setImage(_ image: UIImage?) {
        imageView.image = image
    }

    func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        checkmark.isHidden = !enabled
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        checkmark.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        let changes = {
            self.checkmark.isHidden = !self.isSelectionMode
            self.imageView.alpha = selected ? 0.78 : 1
            self.transform = selected ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        }
        if animated {
            UIView.animate(withDuration: 0.16, animations: changes)
        } else {
            changes()
        }
        if selected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }
}
