import Foundation
import GameProbe
import Observation
import SwiftUI
import Synchronization
import UIKit

/// In-flight import that's still in its pre-flight validation phase.
/// Once the pre-flight passes, the matching `GameEntry` is appended
/// to `games` with `.importing` status and the pending entry is
/// cleared. Progress from that point on lives on the real game
/// card/row. On any pre-flight failure, the pending entry is
/// dropped without the user ever seeing a half-broken skeleton.
///
/// Rendering of the validating state is delegated to the call site:
/// when the library is empty the Import button hoists it onto its
/// own label. When the library already has games the grid/list
/// renders the placeholder card via `entry` so the status
/// feedback stays anchored where the user expects it.
struct PendingImport: Identifiable, Hashable {
    let id: String
    let displayName: String
    let order: Int

    /// Placeholder model rendered in the grid/list while pre-flight
    /// validation runs. Container is nil because nothing is on disk
    /// yet. `importProgress` stays 0, which renders as the
    /// indeterminate spinner inside `GameStatusIndicator` — the
    /// right visual read for the pre-flight phase. Created once (not
    /// per access) so SwiftUI sees one stable card identity across
    /// body passes.
    let entry: GameEntry

    init(id: String, displayName: String, order: Int) {
        self.id = id
        self.displayName = displayName
        self.order = order
        self.entry = GameEntry(
            id: id,
            container: nil,
            title: displayName,
            artworkPath: nil,
            status: .importing
        )
    }
}

enum ImportTemporaryDirectory {
    enum Kind: String {
        case stagedArchive = "staged-archives"
        case archiveChoiceProbe = "archive-choice-probe"
        case folderImport = "folder-import"
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

    /// False until the first catalog pass of this launch has been
    /// merged into `games`. Distinguishes "not scanned yet" from
    /// "scanned and truly empty": before this flips, `games.isEmpty`
    /// means *unknown*, and the UI must not show the empty state.
    /// (The flash was visible under Low Power Mode / heavy load, and
    /// on crash-recovery launches where no splash hides it.)
    var initialScanCompleted = false

    var pendingImports: [String: PendingImport] = [:]
    var nextPendingImportOrder = 0

    /// When each entry last changed locally: `mergeImportedGame`
    /// publishes and `removeLibraryEntry` removals. Scans snapshot
    /// the disk over seconds; a scan that started before a local
    /// change must not overwrite it - or resurrect a deleted
    /// entry's ghost card (`applyScanResults`). Internal because
    /// `removeLibraryEntry` lives in another file.
    var localMutationDates: [String: Date] = [:]

    private let fm = FileManager.default
    nonisolated let cancelledImports = Mutex(Set<String>())

    /// IDs of imports currently extracting / moving on a detached
    /// task. The library scan skips these so a concurrent reload
    /// (triggered by another import finishing) doesn't see a
    /// half-imported container (one where the destination folder
    /// exists but the inner `Game/` subdir hasn't landed yet) and
    /// surface it as an `.invalid` "Unknown Game" entry, which
    /// would clobber the in-memory progress card via the
    /// scan/merge replace step in `reload()`.
    nonisolated let inFlightImports = Mutex(Set<String>())

    /// IDs of containers a detached user-initiated delete is still
    /// removing (a multi-GB rm -rf takes seconds). `planImports`
    /// refuses matching titles and hides these containers from its
    /// installed list so a fast re-import cannot race the running
    /// delete. Registered in `deleteGame` before the task starts;
    /// released by the task when it finishes, aborts, or fails.
    nonisolated let deletionsInFlight = Mutex(Set<String>())

    /// IDs of in-flight imports that update an installed game in
    /// place (user-confirmed replacement). `abandonImport` consults
    /// this: a cancelled or failed replacement must never delete
    /// the container - it still holds the user's saves, settings,
    /// and (the update swaps in atomically or not at all) the
    /// intact installed game - so the existing entry is re-surfaced
    /// instead.
    nonisolated let replacingImports = Mutex(Set<String>())

    nonisolated static var gamesDirectory: URL { GameContainer.rootURL }

    private init() {
        ImportTemporaryDirectory.cleanupStaleDirectories()
        ensureGamesDirectory()
        GameContainerMigration.migrateLegacyContainersIfNeeded()
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
        // Live membership check, NOT a snapshot: the scan can take
        // seconds, and an import (in particular an in-place update
        // of an existing container) registered after this reload
        // started must still be skipped by the loop when it reaches
        // that container. The closure reads the mutex through self
        // because Mutex is noncopyable and cannot bind to a local.
        let isImportInFlight: @Sendable (String) -> Bool = { id in
            self.inFlightImports.withLock { $0.contains(id) }
        }
        let isDeletionInFlight: @Sendable (String) -> Bool = { id in
            self.deletionsInFlight.withLock { $0.contains(id) }
        }
        // .userInitiated: the initial scan gates first meaningful
        // paint (library vs empty state), and later reloads refresh
        // what's on screen. The default detached priority gets
        // deprioritized under system load. That is exactly when the
        // scan is slowest and the priority matters most.
        let scanStartedAt = Date()
        Task.detached(priority: .userInitiated) {
            if initialLoad {
                // Fast pass: titles + metadata + already-extracted
                // artwork, no validation / PE icon extraction /
                // script-profile detection. Gets real cards (and
                // the emptiness answer) on screen quickly. The full
                // pass below corrects status and artwork in place.
                let quick = ImportSignpost.interval("library-quick-scan", id: "reload") {
                    GameCatalog.quickScanGames(
                        isImportInFlight: isImportInFlight,
                        isDeletionInFlight: isDeletionInFlight
                    )
                }
                await MainActor.run {
                    GameLibrary.shared.applyScanResults(quick, scanStartedAt: scanStartedAt)
                }
            }

            let scanned = ImportSignpost.interval("library-scan", id: "reload") {
                GameCatalog.scanGames(
                    cleanupInvalid: cleanupInvalid,
                    isImportInFlight: isImportInFlight,
                    isDeletionInFlight: isDeletionInFlight
                )
            }
            await MainActor.run {
                GameLibrary.shared.applyScanResults(scanned, scanStartedAt: scanStartedAt)
            }
        }
    }

    /// Merge a scan's results into `games`: apply snapshots to
    /// matching models field-by-field (so views only invalidate for
    /// fields that actually changed), drop non-importing entries the
    /// scan no longer sees, append newcomers. Marks the initial scan
    /// complete since any applied pass answers the emptiness
    /// question.
    private func applyScanResults(_ scanned: [GameSnapshot], scanStartedAt: Date) {
        // A scan that raced an import registration can still carry
        // an entry for a container whose import task now owns it
        // (an in-place update's container exists on disk for the
        // scan to see). Applying it would clobber the progress card
        // with a Play-able entry - or append a duplicate-id card -
        // so drop those results; the import's own merge step
        // publishes the final entry.
        let inFlight = inFlightImports.withLock { Set($0) }
        let deleting = deletionsInFlight.withLock { Set($0) }
        // An update that registered, completed, AND published while
        // this scan was running is invisible to the in-flight
        // filter, but the scan's snapshot of that entry predates
        // the update. Keep the fresher local entry. The same shape
        // covers deletions: the scan saw the container before the
        // delete removed it, and appending its entry now would put
        // a ghost card over a gone directory - `deletionsInFlight`
        // catches a delete still running, the mutation date one
        // that already finished.
        let scanned = scanned.filter { entry in
            if inFlight.contains(entry.id) { return false }
            if deleting.contains(entry.id) { return false }
            if let mutated = localMutationDates[entry.id], mutated > scanStartedAt {
                return false
            }
            return true
        }
        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        withAnimation {
            var updatedIDs = Set<String>()
            for model in games {
                if let fresh = scannedByID[model.id] {
                    model.apply(fresh)
                    updatedIDs.insert(model.id)
                }
            }

            // Deleting entries survive too: their scanned twin was
            // filtered out above (`deletionsInFlight`), and dropping
            // the local entry here would vanish the card mid-delete.
            games.removeAll {
                !$0.isImporting && !$0.isDeleting && !scannedByID.keys.contains($0.id)
            }

            for snapshot in scanned where !updatedIDs.contains(snapshot.id) {
                games.append(GameEntry(snapshot))
            }
        }
        if !initialScanCompleted {
            initialScanCompleted = true
        }
    }

    /// Merge a single just-imported container into `games` without
    /// rescanning the whole library. Falls back to a full reload if
    /// the snapshot can't be built (metadata missing, etc.).
    func mergeImportedGame(container: GameContainer) {
        let importID = container.id
        Task.detached {
            let snapshot = GameCatalog.buildSnapshot(from: container)
            await MainActor.run {
                let lib = GameLibrary.shared
                guard let snapshot else {
                    lib.reload()
                    return
                }
                lib.localMutationDates[importID] = Date()
                withAnimation {
                    if let model = lib.games.first(where: { $0.id == importID }) {
                        model.apply(snapshot)
                    } else {
                        lib.games.append(GameEntry(snapshot))
                    }
                }
            }
        }
    }

    /// Rebuild an entry's scan-time fields from disk (title,
    /// artwork, metadata) after something edited them, keeping the
    /// in-memory status. Runs the disk reads off-main; the previous
    /// version rebuilt synchronously on the main thread.
    func refreshGameEntry(id: String) {
        guard let model = games.first(where: { $0.id == id }),
            let container = model.container
        else { return }
        Task.detached(priority: .userInitiated) {
            guard let snapshot = GameCatalog.buildSnapshot(from: container) else { return }
            await MainActor.run {
                let lib = GameLibrary.shared
                guard let model = lib.games.first(where: { $0.id == id }) else { return }
                withAnimation { model.apply(snapshot, preservingStatus: true) }
            }
        }
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
            .map(\.entry)
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
        // Extra safety: every container also gets its own
        // `isExcludedFromBackup` flag, but the flag on the root
        // directory makes iOS skip it entirely if it scans
        // top-down before reaching the children. iOS treats the
        // attribute as inheriting to contents per the URL resource
        // docs, so this single set covers anything inside Games/.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = GameContainer.rootURL
        try? rootURL.setResourceValues(values)

        // Sweep existing containers in case they predate this
        // exclusion (or were created before `ensureSubdirs()` set
        // the flag). Runs once per app launch. Cheap because the
        // setter is a no-op when the flag is already set.
        for container in GameContainer.discover() {
            container.excludeFromBackup()
        }
    }
}
