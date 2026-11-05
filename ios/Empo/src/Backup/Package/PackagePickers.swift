import SwiftUI
import UniformTypeIdentifiers

/// The import picker of SPEC 12.6. It takes ZIP files alone.
struct PackageZipPicker: UIViewControllerRepresentable {

    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.zip], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        picker.view.tintColor = UIColor(.brand)
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
