import SwiftUI
import UniformTypeIdentifiers

/// The export picker of SPEC 12.5.
///
/// Apple gives this picker no byte progress and no resume, so the
/// build sheet shows progress and this shows none. The picker owns
/// the copy once it reports a save.
struct PackageExportPicker: UIViewControllerRepresentable {

    let file: URL
    /// True where Files saved the copy. False where the user
    /// cancelled, which is what brings back the Save again and
    /// Delete choice.
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: true`: Files copies the staged ZIP out, and Empo
        // still holds the staged one until this reports the save.
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        picker.view.tintColor = UIColor(.brand)
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            onFinish(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}

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
