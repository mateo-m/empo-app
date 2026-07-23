import Foundation
import GameProbe

enum SaveMigration {
    /// Marker inserted into backup names while recovering from the
    /// missing-trailing-slash `System.data_directory` regression
    /// (introduced in v0.2.1). Not a PE/RGSS save slot. Games
    /// ignore these files.
    private static let pathRegressionBackupMarker = "empo-path-regression"

    static func migrateLegacySavesIfNeeded(for container: GameContainer) {
        let fm = FileManager.default
        let userDataDir = container.ensureUserDataDirectory()
        migrateConcatenatedUserDataSavesIfNeeded(
            for: container, userDataDir: userDataDir, fileManager: fm)

        let legacyDir = legacySaveDirectory(for: container)

        guard legacyDir.path != userDataDir.path else { return }
        guard fm.fileExists(atPath: legacyDir.path) else { return }

        guard let entryNames = try? fm.contentsOfDirectory(atPath: legacyDir.path) else { return }

        for name in entryNames {
            let entry = legacyDir.appendingPathComponent(name, isDirectory: false)
            let destination = uniqueURL(
                in: userDataDir,
                preferredName: name,
                numberedName: { index in numberedFilename(name, index: index) },
                fileManager: fm)
            do {
                try fm.moveItem(at: entry, to: destination)
            } catch {
                NSLog(
                    "[SaveMigration] Failed to move %@ -> %@: %@",
                    entry.path,
                    destination.path,
                    error.localizedDescription)
            }
        }

        if let leftovers = try? fm.contentsOfDirectory(atPath: legacyDir.path) {
            if leftovers.isEmpty {
                try? fm.removeItem(at: legacyDir)
            } else {
                NSLog(
                    "[SaveMigration] Legacy Application Support directory still contains %ld entr%@ for %@: %@",
                    leftovers.count,
                    leftovers.count == 1 ? "y" : "ies",
                    container.folderName,
                    leftovers.joined(separator: ", "))
            }
        }
    }

    static func migrateAllDiscoveredGamesIfNeeded() {
        for container in GameContainer.discover() {
            migrateLegacySavesIfNeeded(for: container)
        }
    }

    /// Recover saves written at the container root when
    /// `System.data_directory` lacked a trailing slash and a game
    /// concatenated `dir + filename` (e.g. `UserDataGame.rxdata`).
    ///
    /// On conflict with an existing `UserData/<name>` file, the newer
    /// mtime wins the canonical name. The older file stays beside it
    /// as `<name>.empo-path-regression.bak`.
    private static func migrateConcatenatedUserDataSavesIfNeeded(
        for container: GameContainer, userDataDir: URL, fileManager fm: FileManager
    ) {
        let root = container.url
        guard let entryNames = try? fm.contentsOfDirectory(atPath: root.path) else { return }

        for name in entryNames {
            guard let remainder = concatenatedUserDataSaveRemainder(name) else { continue }
            let source = root.appendingPathComponent(name, isDirectory: false)
            guard isRegularFile(source, fileManager: fm) else { continue }

            let canonical = userDataDir.appendingPathComponent(remainder, isDirectory: false)
            do {
                try mergeConcatenatedSave(
                    source: source, canonical: canonical, fileManager: fm)
            } catch {
                NSLog(
                    "[SaveMigration] Failed to recover concatenated save %@ -> %@: %@",
                    source.path,
                    canonical.path,
                    error.localizedDescription)
            }
        }
    }

    private static func mergeConcatenatedSave(
        source: URL, canonical: URL, fileManager fm: FileManager
    ) throws {
        if !fm.fileExists(atPath: canonical.path) {
            try fm.moveItem(at: source, to: canonical)
            NSLog(
                "[SaveMigration] Moved concatenated save %@ -> %@",
                source.path,
                canonical.path)
            return
        }

        let sourceIsNewer =
            modificationDate(of: source, fileManager: fm)
            >= modificationDate(of: canonical, fileManager: fm)
        let backup = uniqueURL(
            in: canonical.deletingLastPathComponent(),
            preferredName: pathRegressionBackupName(
                for: canonical.lastPathComponent),
            numberedName: { index in
                pathRegressionBackupName(
                    for: canonical.lastPathComponent, index: index)
            },
            fileManager: fm)

        if sourceIsNewer {
            try fm.moveItem(at: canonical, to: backup)
            try fm.moveItem(at: source, to: canonical)
            NSLog(
                "[SaveMigration] Promoted newer concatenated save %@ -> %@ (older kept as %@)",
                source.path,
                canonical.path,
                backup.path)
        } else {
            try fm.moveItem(at: source, to: backup)
            NSLog(
                "[SaveMigration] Kept newer %@; archived concatenated save as %@",
                canonical.path,
                backup.path)
        }
    }

    private static func concatenatedUserDataSaveRemainder(_ filename: String) -> String? {
        let prefix = "UserData"
        guard filename.hasPrefix(prefix) else { return nil }
        let remainder = String(filename.dropFirst(prefix.count))
        guard !remainder.isEmpty, isSaveFilename(remainder) else { return nil }
        return remainder
    }

    private static func isSaveFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".bak") {
            return isSaveFilename(String(lower.dropLast(4)))
        }
        return lower.hasSuffix(".rxdata") || lower.hasSuffix(".rvdata") || lower.hasSuffix(".rvdata2")
    }

    /// `Game.rxdata` → `Game.rxdata.empo-path-regression.bak`
    /// (index ≥ 2 → `…empo-path-regression-2.bak`)
    private static func pathRegressionBackupName(
        for filename: String, index: Int = 1
    ) -> String {
        if index <= 1 {
            return "\(filename).\(pathRegressionBackupMarker).bak"
        }
        return "\(filename).\(pathRegressionBackupMarker)-\(index).bak"
    }

    private static func numberedFilename(_ filename: String, index: Int) -> String {
        let url = URL(fileURLWithPath: filename)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
    }

    /// First unused name in `directory`: `preferredName`, then
    /// `numberedName(2…999)`, then a UUID-prefixed fallback.
    private static func uniqueURL(
        in directory: URL,
        preferredName: String,
        numberedName: (Int) -> String,
        fileManager fm: FileManager
    ) -> URL {
        let primary = directory.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: primary.path) else { return primary }

        for index in 2...999 {
            let candidate = directory.appendingPathComponent(numberedName(index))
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent(
            UUID().uuidString + "-" + preferredName)
    }

    private static func isRegularFile(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func modificationDate(of url: URL, fileManager fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func legacySaveDirectory(for container: GameContainer) -> URL {
        let defaults = legacyDataPathDefaults(for: container)
        return applicationSupportDirectory()
            .appendingPathComponent(defaults.org, isDirectory: true)
            .appendingPathComponent(defaults.app, isDirectory: true)
    }

    private static func legacyDataPathDefaults(for container: GameContainer) -> (org: String, app: String) {
        let gameDir = container.gameURL

        if let json = try? Data(contentsOf: gameDir.appendingPathComponent("mkxp.json")),
            let raw = json.decodeAsLooseText(),
            let object = JSON5LiteParser.parseObject(raw)
        {
            let org = normalizedPathComponent(object["dataPathOrg"] as? String) ?? "."
            let app =
                normalizedPathComponent(object["dataPathApp"] as? String)
                ?? normalizedPathComponent(
                    GameINI.parseINIValue(at: gameDir, section: "game", key: "title"))
                ?? "mkxp-z"
            return (org, app)
        }

        let org = "."
        let app =
            normalizedPathComponent(
                GameINI.parseINIValue(at: gameDir, section: "game", key: "title")) ?? "mkxp-z"
        return (org, app)
    }

    private static func normalizedPathComponent(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
