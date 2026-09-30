import PhotosUI
import SwiftUI

/// Keep the provider's suggested filename, which PhotosPicker's Data transfer discards.
struct NamedPhotoPicker: UIViewControllerRepresentable {
  let onSelection: ([PHPickerResult]) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 2
    configuration.selection = .ordered
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let onSelection: ([PHPickerResult]) -> Void
    init(onSelection: @escaping ([PHPickerResult]) -> Void) { self.onSelection = onSelection }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      onSelection(results)
    }
  }
}
