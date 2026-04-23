import SwiftUI
import UniformTypeIdentifiers


extension UTType {
    static let sevenZArchive = UTType(filenameExtension: "7z") ?? .archive
    static let rarArchive    = UTType(filenameExtension: "rar") ?? .archive
    /// JoiPlay archive. Declared via `exportedAs` in Info.plist so
    /// Files.app can open .jgp with us, but we look up the
    /// filename-extension-based UTType first so the document picker
    /// accepts .jgp even when the Launch Services index hasn't
    /// caught up (first run after install, or simulator state).
    /// Falling back to our exported type matches how 7z/rar behave.
    static let jgpArchive    = UTType(filenameExtension: "jgp")
                               ?? UTType(exportedAs: "cyou.joiplay.jgp",
                                         conformingTo: .zip)
}


struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder, .zip, .sevenZArchive, .rarArchive, .jgpArchive]
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.view.tintColor = UIColor(.brand)
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onPick(urls)
        }
    }
}
