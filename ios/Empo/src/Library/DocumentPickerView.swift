// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let sevenZArchive = UTType(filenameExtension: "7z") ?? .archive
    static let rarArchive = UTType(filenameExtension: "rar") ?? .archive
    /// Self-extracting .exe game installers (CAB/7z/RAR/zip payload
    /// behind a Windows extractor stub). Resolves to
    /// com.microsoft.windows-executable via the extension lookup.
    static let exeArchive = UTType(filenameExtension: "exe") ?? .data
    /// JoiPlay archive. The extension lookup comes first, because the
    /// document picker rejects .jgp until Launch Services indexes the
    /// Info.plist type (first run after install, or simulator state).
    static let jgpArchive =
        UTType(filenameExtension: "jgp")
        ?? UTType(
            importedAs: "cyou.joiplay.jgp",
            conformingTo: .zip)

    static let importableGames: [UTType] = [
        .folder, .zip, .sevenZArchive, .rarArchive, .jgpArchive, .exeArchive,
    ]
}

#if os(iOS)
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
            forOpeningContentTypes: UTType.importableGames,
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
#endif
