import GameProbe
import SwiftUI

/// The save-file editor of SPEC 3.7.
///
/// One view in two containers. The first-backup ask presents it as a
/// standalone sheet, and the Backup sheet pushes it inside its own
/// navigation stack.
struct SaveFileEditorView: View {

    let container: GameContainer
    let model: SaveFileEditorModel
    /// `false` while a run for this game is in flight. The rows stay
    /// readable, per 13.17.
    let canEdit: Bool
    let save: (SaveFileEditorModel) -> Void

    @State private var edited: SaveFileEditorModel?

    private var shown: SaveFileEditorModel { edited ?? model }

    var body: some View {
        List {
            Section {
                if shown.entries.isEmpty {
                    Text("Empo found no save file in this game yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(shown.entries, id: \.path) { entry in
                    row(entry)
                }
            } footer: {
                Text(
                    "A save file joins this list on its own. Add one Empo missed, "
                        + "and it stays whatever Empo detects later."
                )
            }

            if canEdit {
                Section {
                    NavigationLink("Add a file or folder") {
                        GameFilePicker(container: container) { path, size in
                            var next = shown
                            next.add(path: path, sizeBytes: size)
                            apply(next)
                        }
                    }
                }
            }
        }
        .navigationTitle("Save files")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: SaveFileEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(entry.path)
                .lineLimit(2)
            HStack(spacing: Spacing.sm) {
                Text(Self.label(of: entry.source))
                Text(BackupText.bytes(entry.sizeBytes))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .swipeActions {
            // Only a mark comes out, per 3.6. A classifier match and
            // a watched write stay.
            if canEdit && entry.isRemovable {
                Button("Remove", role: .destructive) {
                    var next = shown
                    next.remove(path: entry.path)
                    apply(next)
                }
            }
        }
    }

    private func apply(_ next: SaveFileEditorModel) {
        edited = next
        save(next)
    }

    /// The label of the source that found the file, per 3.6.
    private static func label(of source: DetectionSource) -> String {
        switch source {
        case .classifier: return "Empo found it"
        case .runtimeWatch: return "The game wrote it"
        case .manualMark: return "You added it"
        }
    }
}

/// The picker of SPEC 3.6, rooted at the game's `Game/`.
///
/// It walks the game's own files instead of asking the system
/// picker. The system picker copies what it returns, and a mark
/// names a path inside the container that has to stay where it is.
struct GameFilePicker: View {

    let container: GameContainer
    var directory: URL?
    let mark: (String, Int64) -> Void

    @Environment(\.dismiss) private var dismiss

    private var url: URL { directory ?? container.gameURL }

    private var entries: [URL] {
        let found =
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        List {
            ForEach(entries, id: \.path) { entry in
                if Self.isDirectory(entry) {
                    NavigationLink {
                        GameFilePicker(container: container, directory: entry, mark: mark)
                    } label: {
                        row(entry, isDirectory: true)
                    }
                    .swipeActions {
                        Button("Add") { add(entry) }
                    }
                } else {
                    Button {
                        add(entry)
                    } label: {
                        row(entry, isDirectory: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: URL, isDirectory: Bool) -> some View {
        HStack {
            Image(systemName: isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(entry.lastPathComponent)
            Spacer()
            if !isDirectory {
                Text(BackupText.bytes(Self.size(of: entry)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ entry: URL) {
        let root = container.url.standardizedFileURL.path + "/"
        let path = entry.standardizedFileURL.path
        guard path.hasPrefix(root) else { return }
        mark(String(path.dropFirst(root.count)), Self.size(of: entry))
        dismiss()
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
