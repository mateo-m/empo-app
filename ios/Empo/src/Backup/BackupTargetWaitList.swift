import Foundation
import GameProbe

/// A JSON file of target ids that still wait for one step, kept beside
/// the backup records. A target can be offline when the step comes up,
/// so its id stays in the file until its next run does the step.
///
/// A damaged file makes every target wait, so the step must be safe to
/// do again.
@MainActor
struct BackupTargetWaitList {

    let fileURL: URL

    init(fileName: String) {
        fileURL = BackupRoot.layout.root.appendingPathComponent(fileName)
    }

    func ids() throws -> Set<String> {
        guard let data = try SettingsFile.data(at: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode(Set<String>.self, from: data)
        } catch is DecodingError {
            // The damaged file stays until its replacement is saved, so a failure here makes
            // every target wait again at the next read.
            let every = Set(try BackupTargets.read().map(\.id))
            try BackupRoot.copyAside(fileURL)
            try write(every)
            return every
        }
    }

    func add(_ added: Set<String>) throws {
        guard !added.isEmpty else { return }
        try write(try ids().union(added))
    }

    func remove(_ id: String) throws {
        var left = try ids()
        guard left.remove(id) != nil else { return }
        try write(left)
    }

    private func write(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {}
            return
        }
        try JSONEncoder().encode(ids.sorted()).write(to: fileURL, options: .atomic)
    }
}
