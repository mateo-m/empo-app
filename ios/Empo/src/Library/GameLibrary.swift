import Foundation
import GameProbe
import Observation
import SwiftUI
import Synchronization
import UIKit

/// In-flight import that's still in its pre-flight validation phase.
/// Once the pre-flight passes, the matching `GameEntry` is appended
/// to `games` with `.importing(progress:)` status and the pending
/// entry is cleared - progress from that point on lives on the real
/// game card/row. On any pre-flight failure, the pending entry is
/// dropped without the user ever seeing a half-broken skeleton.
///
/// Rendering of the validating state is delegated to the call site:
/// when the library is empty the Import button hoists it onto its
/// own label; when the library already has games the grid/list
/// renders a synthetic card via `syntheticEntry` so the status
/// feedback stays anchored where the user expects it.
struct PendingImport: Identifiable, Hashable {
    let id: String
    let displayName: String
    let order: Int

    /// Placeholder `GameEntry` used when rendering the pending
    /// import inside the existing grid/list. Container is nil
    /// because nothing is on disk yet; `progress: 0` renders as
    /// the indeterminate spinner inside `GameStatusIndicator`,
    /// which is the right visual read for the pre-flight phase.
    var syntheticEntry: GameEntry {
        GameEntry(
            id: id,
            container: nil,
            title: displayName,
            artworkPath: nil,
            status: .importing(progress: 0)
        )
    }
}

enum ImportTemporaryDirectory {
    enum Kind: String {
        case stagedArchive = "staged-archives"
        case archiveChoiceProbe = "archive-choice-probe"
        case folderImport = "folder-import"
        case archivePreflight = "archive-preflight"
        case archiveImport = "archive-import"
    }

    static var rootURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("empo-import", isDirectory: true)
    }

    static func makeScopedDirectory(
        kind: Kind,
        fm: FileManager = .default
    ) throws -> URL {

        let directoryURL =
            rootURL
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    static func cleanupStaleDirectories(fm: FileManager = .default) {
        try? fm.removeItem(at: rootURL)
    }
}

@MainActor @Observable
class GameLibrary {
    static let shared = GameLibrary()

    var games: [GameEntry] = []
    var pendingImports: [String: PendingImport] = [:]
    var nextPendingImportOrder = 0

    private let fm = FileManager.default
    nonisolated let cancelledImports = Mutex(Set<String>())

    /// IDs of imports currently extracting / moving on a detached
    /// task. The library scan skips these so a concurrent reload
    /// (triggered by another import finishing) doesn't see a
    /// half-imported container - i.e. one where the destination
    /// folder exists but the inner `Game/` subdir hasn't landed
    /// yet - and surface it as an `.invalid` "Unknown Game" entry,
    /// clobbering the in-memory progress card via the
    /// scan/merge replace step in `reload()`.
    nonisolated let inFlightImports = Mutex(Set<String>())

    nonisolated static var gamesDirectory: URL { GameContainer.rootURL }

    private init() {
        ImportTemporaryDirectory.cleanupStaleDirectories()
        ensureGamesDirectory()
        SaveMigration.migrateAllDiscoveredGamesIfNeeded()
        // Initial scan runs off-main via reload(). The library is
        // observable and empty until the scan completes, which keeps
        // first render of the library instant on cold storage.
        reload(initialLoad: true)
    }

    func reload(initialLoad: Bool = false) {
        let cleanupInvalid =
            initialLoad
            ? UserDefaults.standard.bool(forKey: DefaultsKey.cleanupInvalidGames)
            : false
        let skipIDs = inFlightImports.withLock { Set($0) }
        Task.detached {
            let scanned = GameCatalog.scanGames(
                cleanupInvalid: cleanupInvalid,
                skipIDs: skipIDs
            )
            let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

            await MainActor.run {
                let lib = GameLibrary.shared
                withAnimation {
                    var updatedIDs = Set<String>()
                    for i in lib.games.indices {
                        let id = lib.games[i].id
                        if let fresh = scannedByID[id] {
                            if lib.games[i] != fresh {
                                lib.games[i] = fresh
                            }
                            updatedIDs.insert(id)
                        }
                    }

                    lib.games.removeAll { !$0.isImporting && !scannedByID.keys.contains($0.id) }

                    for entry in scanned where !updatedIDs.contains(entry.id) {
                        lib.games.append(entry)
                    }
                }
            }
        }
    }

    func refreshGameEntry(id: String) {
        guard let idx = games.firstIndex(where: { $0.id == id }),
            let container = games[idx].container
        else { return }
        guard var entry = GameCatalog.buildGameEntry(from: container) else { return }
        entry.status = games[idx].status  // preserve current status
        withAnimation { games[idx] = entry }
    }

    /// Filtered + sorted catalog for the library grid/list. Reads
    /// `games` so SwiftUI Observation tracks reloads.
    func displayedCatalog(
        search: String,
        sort: LibrarySortOption,
        sizes: [String: Int64]
    ) -> [GameEntry] {
        let base =
            search.isEmpty
            ? games
            : games.filter { $0.title.localizedCaseInsensitiveContains(search) }
        return sort.sort(base, sizes: sizes)
    }

    /// Pre-flight import placeholders shown above the catalog when
    /// the library already has games.
    func pendingValidationCatalog() -> [GameEntry] {
        guard !games.isEmpty else { return [] }
        return pendingImports.values
            .sorted { $0.order < $1.order }
            .map(\.syntheticEntry)
    }

    /// Hero card candidate for "Continue playing", or nil.
    func recentlyPlayedCandidate(
        showContinuePlaying: Bool,
        searchText: String
    ) -> GameEntry? {
        guard showContinuePlaying, searchText.isEmpty else { return nil }
        let readyGames = games.filter { $0.status == .ready }
        guard readyGames.count > 1 else { return nil }
        return
            readyGames
            .filter { $0.lastPlayed != nil }
            .max(by: { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) })
    }

    func ensureGamesDirectory() {
        if !fm.fileExists(atPath: GameContainer.rootURL.path) {
            try? fm.createDirectory(at: GameContainer.rootURL, withIntermediateDirectories: true)
        }
        // Belt-and-suspenders: even though every container also
        // gets its own `isExcludedFromBackup` flag, marking the
        // root directory ensures iOS skips it entirely if it scans
        // top-down before reaching the children. iOS treats the
        // attribute as inheriting to contents per the URL resource
        // docs, so this single set covers anything inside Games/.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = GameContainer.rootURL
        try? rootURL.setResourceValues(values)

        // Sweep existing containers in case they predate this
        // exclusion (or were created before `ensureSubdirs()` set
        // the flag). One-shot per app launch; cheap because the
        // setter is a no-op when the flag is already set.
        for container in GameContainer.discover() {
            container.excludeFromBackup()
        }
    }
}
