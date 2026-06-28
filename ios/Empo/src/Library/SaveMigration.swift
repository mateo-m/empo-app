import Foundation
import GameProbe

enum SaveMigration {
    static func migrateLegacySavesIfNeeded(for container: GameContainer) {
        let fm = FileManager.default
        let userDataDir = container.ensureUserDataDirectory()
        let legacyDir = legacySaveDirectory(for: container)

        guard legacyDir.path != userDataDir.path else { return }
        guard fm.fileExists(atPath: legacyDir.path) else { return }

        guard let entryNames = try? fm.contentsOfDirectory(atPath: legacyDir.path) else { return }

        let entries = entryNames.map {
            legacyDir.appendingPathComponent($0, isDirectory: false)
        }

        for entry in entries {
            let destination = uniqueDestination(
                for: entry.lastPathComponent,
                in: userDataDir,
                fileManager: fm)
            do {
                if fm.fileExists(atPath: destination.path) { continue }
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

    private static func uniqueDestination(
        for filename: String, in directory: URL, fileManager fm: FileManager
    ) -> URL {
        let base = directory.appendingPathComponent(filename)
        guard fm.fileExists(atPath: base.path) else { return base }

        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension

        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return directory.appendingPathComponent(UUID().uuidString + "-" + filename)
    }
}
