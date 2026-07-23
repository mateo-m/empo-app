import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let sevenZArchive = UTType(filenameExtension: "7z") ?? .archive
    static let rarArchive = UTType(filenameExtension: "rar") ?? .archive
    /// Self-extracting .exe game installers (CAB/7z/RAR/zip payload
    /// behind a Windows extractor stub). Resolves to
    /// com.microsoft.windows-executable via the extension lookup.
    static let exeArchive = UTType(filenameExtension: "exe") ?? .data
    /// JoiPlay archive. Declared via `exportedAs` in Info.plist so
    /// Files.app can open .jgp with us, but we look up the
    /// filename-extension-based UTType first so the document picker
    /// accepts .jgp even when the Launch Services index hasn't
    /// caught up (first run after install, or simulator state).
    /// Falling back to our exported type matches how 7z/rar behave.
    static let jgpArchive =
        UTType(filenameExtension: "jgp")
        ?? UTType(
            exportedAs: "cyou.joiplay.jgp",
            conformingTo: .zip)
}

struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // `asCopy: true`: iOS copies the picked file/folder into our
        // app's tmp directory and hands us a regular file:// URL,
        // no security-scoped resource involved. We extract / copy
        // game files immediately on import anyway, so we never
        // needed the security scope.
        //
        // Why this matters for sideloaded installs: on-device
        // resigners (ESign, Feather/Zsign with empty entitlements
        // path) drop the entitlements blob during resign. Without
        // entitlements iOS won't grant the app a sandbox extension
        // for the picked URL, so the security-scoped picker hangs
        // (folder: spinner forever) or silently no-ops (file: Open
        // does nothing). asCopy bypasses that whole grant flow.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [
                .folder, .zip, .sevenZArchive, .rarArchive, .jgpArchive, .exeArchive,
            ],
            asCopy: true
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
