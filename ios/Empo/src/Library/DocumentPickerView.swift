import SwiftUI
import UniformTypeIdentifiers


extension UTType {
    static let sevenZArchive = UTType(filenameExtension: "7z") ?? .archive
    static let rarArchive    = UTType(filenameExtension: "rar") ?? .archive
}


struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder, .zip, .sevenZArchive, .rarArchive]
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
