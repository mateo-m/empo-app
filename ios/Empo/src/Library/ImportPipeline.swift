import Foundation
import GameProbe
import Observation
import SwiftUI
import Synchronization

struct QueuedImportRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let archiveName: String

    init(id: UUID = UUID(), sourceURL: URL, archiveName: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.archiveName = archiveName ?? sourceURL.deletingPathExtension().lastPathComponent
    }
}

struct ImportSelection: Hashable, Sendable {
    let relativePath: String
    let displayName: String

    init(relativePath: String, displayName: String) {
        self.relativePath = relativePath
        self.displayName = displayName
    }

    init(choice: GameImportValidator.ImportRootChoice) {
        self.init(relativePath: choice.relativePath, displayName: choice.title)
    }
}

struct ImportRootPrompt: Identifiable {
    let request: QueuedImportRequest
    let choices: [GameImportValidator.ImportRootChoice]

    var id: UUID { request.id }
}

struct ImportPipelineAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ImportPreparedSource: Hashable, Sendable {
    let workingURL: URL
    let cleanupDirectoryURL: URL?

    func cleanup() {
        guard let cleanupDirectoryURL else { return }
        try? FileManager.default.removeItem(at: cleanupDirectoryURL)
    }
}

struct ImportPipelineSession {
    enum State {
        case staging
        case probing
        case awaitingChoice([GameImportValidator.ImportRootChoice])
        case launching
    }

    let request: QueuedImportRequest
    var preparedSource: ImportPreparedSource?
    var state: State
}

@MainActor @Observable
final class ImportPipeline {
    private(set) var currentSession: ImportPipelineSession?
    private(set) var alert: ImportPipelineAlert?

    @ObservationIgnored private var queue: [QueuedImportRequest] = []
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var library: GameLibrary?

    var activePrompt: ImportRootPrompt? {
        guard let currentSession else { return nil }
        guard case .awaitingChoice(let choices) = currentSession.state else { return nil }
        return ImportRootPrompt(request: currentSession.request, choices: choices)
    }

    var importButtonPhase: ImportButton.Phase {
        if activePrompt != nil {
            return .multipleGames
        }
        if currentSession != nil || library?.pendingImports.isEmpty == false {
            return .validating
        }
        return .idle
    }

    func configure(library: GameLibrary) {
        self.library = library
    }

    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls.map { QueuedImportRequest(sourceURL: $0) })
        startNextResolutionIfPossible()
    }

    func dismissAlert() {
        alert = nil
    }

    func dismissPrompt() {
        cancelChoice()
    }

    func cancelChoice() {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        currentSession.preparedSource?.cleanup()
        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    func confirmChoice(_ choices: [GameImportValidator.ImportRootChoice]) {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        launchImports(
            choices.map(ImportSelection.init(choice:)),
            for: currentSession.request.id
        )
    }

    func cancelValidation() {
        queue.removeAll()
        cancelCurrentResolution()
        guard let library else { return }
        for id in library.pendingImports.keys {
            library.cancelPendingImport(id)
        }
    }

    private func startNextResolutionIfPossible() {
        guard currentSession == nil else { return }
        guard !queue.isEmpty else { return }

        beginResolution(for: queue.removeFirst())
    }

    private func beginResolution(for request: QueuedImportRequest) {
        currentSession = ImportPipelineSession(request: request, state: .staging)

        resolutionTask = Task {
            do {
                let preparedSource = try await ImportPipelineService.prepareSource(for: request)
                guard isCurrentSession(request.id) else {
                    preparedSource.cleanup()
                    return
                }

                currentSession?.preparedSource = preparedSource
                currentSession?.state = .probing

                let choices = try await ImportPipelineService.probeChoices(for: preparedSource)
                guard isCurrentSession(request.id) else {
                    preparedSource.cleanup()
                    return
                }

                if choices.count > 1 {
                    currentSession?.state = .awaitingChoice(choices)
                    resolutionTask = nil
                } else {
                    launchImports(choices.map(ImportSelection.init(choice:)), for: request.id)
                }
            } catch is CancellationError {
                guard isCurrentSession(request.id) else { return }
                currentSession?.preparedSource?.cleanup()
                currentSession = nil
                resolutionTask = nil
                startNextResolutionIfPossible()
            } catch {
                guard isCurrentSession(request.id) else { return }

                currentSession?.preparedSource?.cleanup()
                currentSession = nil
                resolutionTask = nil
                presentError(
                    title: "Couldn't import \(quoted(request.archiveName))",
                    message: error.localizedDescription
                )
                startNextResolutionIfPossible()
            }
        }
    }

    private func launchImports(_ selections: [ImportSelection], for requestID: UUID) {
        guard var currentSession else { return }
        guard currentSession.request.id == requestID else { return }
        guard let preparedSource = currentSession.preparedSource else {
            self.currentSession = nil
            resolutionTask = nil
            startNextResolutionIfPossible()
            return
        }

        currentSession.state = .launching
        self.currentSession = currentSession
        resolutionTask = nil

        startImports(
            from: preparedSource,
            archiveName: currentSession.request.archiveName,
            selections: selections
        )

        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    private func startImports(
        from preparedSource: ImportPreparedSource,
        archiveName: String,
        selections: [ImportSelection]
    ) {
        guard !selections.isEmpty else {
            preparedSource.cleanup()
            return
        }

        guard let library else {
            preparedSource.cleanup()
            presentError(
                title: "Couldn't import \(quoted(archiveName))",
                message: "Import system is unavailable right now."
            )
            return
        }

        let completionTracker = ImportCompletionTracker(count: selections.count) {
            preparedSource.cleanup()
        }

        for selection in selections {
            startImport(
                with: library,
                from: preparedSource.workingURL,
                archiveName: archiveName,
                selection: selection,
                completionTracker: completionTracker
            )
        }
    }

    private func startImport(
        with library: GameLibrary,
        from url: URL,
        archiveName: String,
        selection: ImportSelection,
        completionTracker: ImportCompletionTracker
    ) {
        let accessing = url.startAccessingSecurityScopedResource()

        library.pipelineImportGame(
            from: url,
            preferredGameRootRelativePath: selection.relativePath,
            preferredDisplayName: selection.displayName
        ) { error in
            if accessing { url.stopAccessingSecurityScopedResource() }

            if let error {
                if error is GameLibrary.ImportCancelled {
                    // User cancelled; finish cleanup without surfacing UI.
                } else {
                    self.presentError(
                        title: "Couldn't import \(quoted(archiveName))",
                        message: error.localizedDescription
                    )
                }
            } else {
                Haptics.impact()
            }

            completionTracker.finishOne()
        }
    }

    private func cancelCurrentResolution() {
        guard let currentSession else { return }

        resolutionTask?.cancel()
        resolutionTask = nil
        currentSession.preparedSource?.cleanup()
        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    private func isCurrentSession(_ requestID: UUID) -> Bool {
        currentSession?.request.id == requestID
    }

    private func presentError(title: String, message: String) {
        alert = ImportPipelineAlert(title: title, message: message)
    }
}

private final class ImportCompletionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let onComplete: @Sendable () -> Void

    init(count: Int, onComplete: @escaping @Sendable () -> Void) {
        remaining = count
        self.onComplete = onComplete
    }

    func finishOne() {
        let shouldComplete: Bool = lock.withLock {
            remaining -= 1
            return remaining == 0
        }

        if shouldComplete {
            onComplete()
        }
    }
}

private enum ImportPipelineService {
    static func prepareSource(for request: QueuedImportRequest) async throws -> ImportPreparedSource {
        try await Task(priority: .userInitiated) {
            try prepareSourceSync(for: request)
        }
        .value
    }

    static func probeChoices(
        for preparedSource: ImportPreparedSource
    ) async throws -> [GameImportValidator.ImportRootChoice] {
        try await Task(priority: .userInitiated) {
            try probeChoicesSync(for: preparedSource)
        }
        .value
    }

    private static func prepareSourceSync(for request: QueuedImportRequest) throws -> ImportPreparedSource {
        let url = request.sourceURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard ArchiveExtractor.Format(extension: url.pathExtension) != nil else {
            return ImportPreparedSource(
                workingURL: url,
                cleanupDirectoryURL: nil
            )
        }

        let fm = FileManager.default
        let archiveCopyDirectoryURL = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .stagedArchive,
            fm: fm
        )
        let archiveCopyURL = archiveCopyDirectoryURL.appendingPathComponent(url.lastPathComponent)
        var copied = false
        defer {
            if !copied {
                try? fm.removeItem(at: archiveCopyDirectoryURL)
            }
        }

        try fm.copyItem(at: url, to: archiveCopyURL)
        copied = true

        return ImportPreparedSource(workingURL: archiveCopyURL, cleanupDirectoryURL: archiveCopyDirectoryURL)
    }

    private static func probeChoicesSync(
        for preparedSource: ImportPreparedSource
    ) throws -> [GameImportValidator.ImportRootChoice] {
        let url = preparedSource.workingURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        return try GameImportValidator.importRootChoices(for: url)
    }
}

private func quoted(_ value: String) -> String {
    "\"\(value)\""
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

extension GameLibrary {
    struct ImportCancelled: Error {}

    /// Errors surfaced from the import pipeline with display-ready
    /// messages. Used to remap low-level Foundation errors (disk
    /// full, permission denied) into text the user can act on.
    enum ImportError: LocalizedError {
        case outOfSpace

        var errorDescription: String? {
            switch self {
            case .outOfSpace:
                return "Not enough space to import. Free up space on your device and try again."
            }
        }
    }

    /// True when `error` is the Foundation / POSIX flavor of "disk
    /// full". Covers both `NSFileWriteOutOfSpaceError` (from
    /// FileManager writes) and `ENOSPC` (from libc-level calls that
    /// libarchive bubbles up as NSError).
    nonisolated static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) {
            return true
        }
        return false
    }

    nonisolated func isImportCancelled(_ id: String) -> Bool {
        cancelledImports.withLock { $0.contains(id) }
    }

    nonisolated func cancelImport(_ id: String) {
        cancelledImports.withLock { _ = $0.insert(id) }
    }

    nonisolated func clearCancellation(_ id: String) {
        cancelledImports.withLock { _ = $0.remove(id) }
    }

    /// Cancel an import that's still in its pre-validation phase
    /// (visible only via `pendingImports`). The detached task sees
    /// the cancellation flag at its next checkpoint, unwinds temp
    /// files, and removes the pending entry.
    func cancelPendingImport(_ importID: String) {
        cancelImport(importID)
    }

    /// Tear down an in-flight import: drop pending/card UI state and
    /// delete any partial container directory on disk. Shared when
    /// the user cancels and when the import pipeline errors out so
    /// orphans don't resurface as Invalid cards on the next scan.
    @MainActor
    func abandonImport(importID: String, container: GameContainer?) {
        _ = pendingImports.removeValue(forKey: importID)
        let entry = games.first(where: { $0.id == importID })
        let resolvedContainer =
            container ?? entry?.container ?? Self.containerOnDisk(importID: importID)
        removeLibraryEntry(id: importID)
        Self.deleteContainer(resolvedContainer)
    }

    /// Remove a library card from memory (artwork cache + `games`).
    @MainActor
    func removeLibraryEntry(id: String) {
        if let artworkPath = games.first(where: { $0.id == id })?.artworkPath {
            ImageCache.shared.evict(path: artworkPath)
        }
        withAnimation {
            games.removeAll { $0.id == id }
        }
    }

    nonisolated static func containerOnDisk(importID: String) -> GameContainer? {
        GameContainer.discover().first { $0.id == importID }
    }

    /// Recursively delete a game container. `onError` is set for
    /// user-initiated deletes; import abandon passes nil so a
    /// failed cleanup stays silent.
    nonisolated static func deleteContainer(
        _ container: GameContainer?,
        onError: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        guard let container else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: container.url.path) else { return }
                // One rm -rf nukes Game/, EmpoState/, Logs/, and
                // Metadata/ together - per-game saves, settings,
                // logs, custom artwork, and crash markers all go
                // in a single call.
                try container.deleteAll()
            } catch {
                NSLog("[GameLibrary] Delete error: %@", "\(error)")
                guard let onError else { return }
                await MainActor.run {
                    GameLibrary.shared.reload()
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func pipelineImportGame(
        from sourceURL: URL,
        preferredGameRootRelativePath: String? = nil,
        preferredDisplayName: String? = nil,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        ensureGamesDirectory()

        let archiveFormat = ArchiveExtractor.Format(extension: sourceURL.pathExtension)
        let importID = UUID().uuidString
        let sourceName =
            archiveFormat == nil
            ? sourceURL.lastPathComponent
            : sourceURL.deletingPathExtension().lastPathComponent
        let pendingDisplayName = preferredDisplayName ?? sourceName
        let pendingOrder = nextPendingImportOrder
        nextPendingImportOrder += 1

        // Pre-flight phase: button shows "Validating", library keeps
        // its current UI (empty state or existing list). Once
        // pre-flight passes a progress card is committed to `games` and
        // extraction/finalisation runs with the card visible.
        pendingImports[importID] = PendingImport(
            id: importID,
            displayName: pendingDisplayName,
            order: pendingOrder
        )
        // Mark the import as in-flight so concurrent library scans
        // (triggered by sibling imports finishing) skip this
        // container until the move is committed and metadata is
        // written. Removed in the detached task's defer.
        inFlightImports.withLock { _ = $0.insert(importID) }

        Task.detached(priority: .userInitiated) {
            defer { self.clearCancellation(importID) }
            // Drop from in-flight set BEFORE queuing the reload
            // call so the post-completion scan sees this container
            // as a normal candidate (not skipped). Doing this in a
            // `defer` would push it past the `await MainActor.run`
            // closure and reload's scan would still treat the
            // just-finished import as in-flight, leaving the card
            // stuck on `.importing` forever.
            let markNotInFlight = {
                self.inFlightImports.withLock { _ = $0.remove(importID) }
            }
            do {
                if archiveFormat != nil {
                    try self.importArchive(
                        from: sourceURL,
                        importID: importID,
                        sourceName: sourceName,
                        preferredGameRootRelativePath: preferredGameRootRelativePath
                    )
                } else {
                    try self.importFolder(
                        from: sourceURL,
                        importID: importID,
                        sourceName: sourceName,
                        preferredGameRootRelativePath: preferredGameRootRelativePath
                    )
                }
                markNotInFlight()
                await MainActor.run {
                    GameLibrary.shared.reload()
                    completion(nil)
                }
            } catch is ImportCancelled {
                markNotInFlight()
                NSLog("[GameLibrary] Import cancelled: %@", importID)
                await MainActor.run {
                    GameLibrary.shared.abandonImport(importID: importID, container: nil)
                    completion(ImportCancelled())
                }
            } catch {
                markNotInFlight()
                NSLog("[GameLibrary] Import error: %@", "\(error)")
                let surfaced: Error = Self.isOutOfSpace(error) ? ImportError.outOfSpace : error
                await MainActor.run {
                    GameLibrary.shared.abandonImport(importID: importID, container: nil)
                    completion(surfaced)
                }
            }
        }
    }

    /// Commits a progress-card `GameEntry` to `games` and drops the
    /// matching pending entry. Called from the import pipeline once
    /// pre-flight validation passes - from this point on the user
    /// can see and cancel the import from the card itself.
    nonisolated func commitPendingToCard(
        _ importID: String,
        container: GameContainer,
        title: String,
        artworkPath: String?
    ) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            withAnimation {
                _ = lib.pendingImports.removeValue(forKey: importID)
                lib.games.append(
                    GameEntry(
                        id: importID,
                        container: container,
                        title: title,
                        artworkPath: artworkPath,
                        status: .importing(progress: 0)
                    ))
            }
        }
    }

    /// Swap in the card's artwork mid-extract, once the archive
    /// has yielded a `Graphics/Titles/*` image or `.exe` icon.
    /// Called more than once per import: each time the extractor
    /// finds an alphabetically-smaller candidate the card updates
    /// to match, mirroring the rule used by `findArtwork` after
    /// the full extract completes so the card doesn't flicker to
    /// a different artwork when the import finishes. Rebuilding
    /// the entry (rather than mutating `artworkPath` on the
    /// existing one) goes through SwiftUI's normal diffing so the
    /// card cross-fades the placeholder to the real artwork.
    nonisolated func updateCardArtwork(_ importID: String, artworkPath: String) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            // No early-return on same path. The mid-extract sidecar
            // is at a fixed location (`<container>/Metadata/exe-icon.png`)
            // and gets overwritten on disk when a later .exe in the
            // archive supersedes the earlier pick (e.g. Reborn1950
            // ships [Patcher.exe (skipped), Reborn.exe, Game.exe] -
            // Reborn writes first, Game.exe overwrites). The path
            // string is unchanged across those writes so a guard
            // here would skip the SwiftUI re-render and the card
            // would keep showing the first icon decoded into the
            // ImageCache - until reload-time view rebuild swaps it
            // for the latest disk content, producing a visible
            // mid-import-vs-final mismatch. Always rebuilding the
            // entry forces the body re-eval, which re-reads cache
            // (already evicted at write time), so the displayed
            // icon tracks disk state.
            withAnimation {
                lib.games[idx] = GameEntry(
                    id: importID,
                    container: lib.games[idx].container,
                    title: lib.games[idx].title,
                    artworkPath: artworkPath,
                    engineTitle: lib.games[idx].engineTitle,
                    lastPlayed: lib.games[idx].lastPlayed,
                    dateAdded: lib.games[idx].dateAdded,
                    status: lib.games[idx].status
                )
            }
        }
    }

    /// Updates the extraction progress on the already-committed
    /// progress card (not on `pendingImports`, which was cleared
    /// once pre-flight passed).
    nonisolated func updateCardProgress(_ importID: String, _ progress: Double) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            let entry = lib.games[idx]
            lib.games[idx] = GameEntry(
                id: entry.id,
                container: entry.container,
                title: entry.title,
                artworkPath: entry.artworkPath,
                engineTitle: entry.engineTitle,
                lastPlayed: entry.lastPlayed,
                dateAdded: entry.dateAdded,
                status: .importing(progress: progress)
            )
        }
    }

    nonisolated func importFolder(
        from sourceURL: URL,
        importID: String,
        sourceName: String,
        preferredGameRootRelativePath: String?
    ) throws {
        let fm = FileManager.default
        let folderName = sourceURL.lastPathComponent

        let tmpDir = try ImportTemporaryDirectory.makeScopedDirectory(kind: .folderImport, fm: fm)
        let tmpDest = tmpDir.appendingPathComponent(folderName)
        defer { try? fm.removeItem(at: tmpDir) }

        // Pre-flight: copy once into tmp (cheaper than moving the
        // source and having no rollback if validation fails) and
        // validate the copy. This is the only "Validating" phase
        // the user sees on the button.
        try fm.copyItem(at: sourceURL, to: tmpDest)
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try {
            try GameImportValidator.validate(tmpDest)
            if let preferredGameRootRelativePath {
                return try GameImportValidator.resolveGameRoot(
                    in: tmpDest,
                    relativePath: preferredGameRootRelativePath
                )
            }
            return GameImportValidator.locateGameRoot(in: tmpDest) ?? tmpDest
        }()
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        // Pre-flight passed - commit the progress card so the rest
        // of the import has a visible home for progress/cancel UI.
        let title = GameINI.parseINIValue(at: gameRoot, section: "game", key: "title") ?? sourceName
        let container = GameContainer(id: importID, slug: GameContainer.slugify(title))

        // Lazy: write the exe-icon sidecar into Metadata/ from the
        // tmp tree before the move, so the committed card has
        // something to display. ExecutableIconExtractor's static
        // helper is keyed off a game-folder URL; pass the tmp
        // location, then re-target the resulting sidecar path
        // afterwards. (For folder imports, sidecars are uncommon
        // because folder imports are usually pre-extracted RGSS
        // trees with `Graphics/Titles/` already present.)
        let artworkPath = GameCatalog.findFolderImportArtwork(at: gameRoot)
        if let path = artworkPath {
            // Warm the decode cache before `tmpDest`'s defer-backed
            // cleanup kicks in so the card keeps rendering the
            // artwork across the move-then-reload window.
            _ = ImageCache.shared.image(for: path)
        }
        commitPendingToCard(
            importID, container: container,
            title: title, artworkPath: artworkPath)

        // Folder imports don't have a meaningful extraction-progress
        // phase (the heavy copy already happened in the pre-flight).
        // Jump directly to the move; if the card gets cancelled in
        // the brief window before the move finishes, the cancel
        // path below cleans up.
        updateCardProgress(importID, 1.0)

        var committed = false
        defer {
            if !committed {
                try? container.deleteAll()
            }
        }

        try fm.createDirectory(at: container.url, withIntermediateDirectories: true)
        try fm.moveItem(at: gameRoot, to: container.gameURL)

        if isImportCancelled(importID) { throw ImportCancelled() }

        // Lazy: extract the exe-icon sidecar from the now-final
        // location, writing into Metadata/. Idempotent (skipped if
        // already present), so repeat imports are cheap.
        _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)

        GameImporter.seedFolderImport(in: container)
        committed = true
    }

    nonisolated func importArchive(
        from sourceURL: URL,
        importID: String,
        sourceName: String,
        preferredGameRootRelativePath: String?
    ) throws {
        let fm = FileManager.default

        // Pre-flight scratch: throwaway dir for selectively
        // extracting just the validation files. Lives only for the
        // length of the pre-flight phase.
        let preflightDir = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .archivePreflight,
            fm: fm
        )
        defer { try? fm.removeItem(at: preflightDir) }

        let preflightRoot: URL
        do {
            preflightRoot = try GameImportValidator.preflightArchive(
                at: sourceURL,
                scratchDir: preflightDir,
                preferredGameRootRelativePath: preferredGameRootRelativePath,
                shouldCancel: { self.isImportCancelled(importID) }
            )
        } catch ArchiveExtractor.Error.cancelled {
            throw ImportCancelled()
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        // Pre-flight passed - pick up the title from the extracted
        // `.ini` so the committed card shows the real name while the
        // rest of the archive extracts in the background. Artwork
        // fills in mid-extract via the extract() callback below.
        let title = GameINI.parseINIValue(at: preflightRoot, section: "game", key: "title") ?? sourceName
        let container = GameContainer(id: importID, slug: GameContainer.slugify(title))
        commitPendingToCard(
            importID, container: container,
            title: title, artworkPath: nil)

        var committed = false
        defer {
            if !committed {
                try? container.deleteAll()
            }
        }

        // Full extraction now runs visibly - progress feeds the
        // committed card's `.importing(progress:)` status.
        let tmpDir = try ImportTemporaryDirectory.makeScopedDirectory(kind: .archiveImport, fm: fm)
        defer { try? fm.removeItem(at: tmpDir) }

        // Mid-extract artwork surfacing - .exe icon ONLY.
        //
        // Earlier this also surfaced `Graphics/Titles/*` images as
        // a fallback when no `.exe` had landed yet. That produced
        // a visible artwork flash for games whose archive ordering
        // happened to put title images before the executable
        // (Reborn1950.zip is one such): mid-import would show the
        // title screen, then late-extract or post-import reload
        // would replace it with the `.exe` icon that
        // `findArtwork` picks. The two-stage surface
        // never matched what the user would see post-import, so
        // we just don't surface the titles fallback during
        // extract anymore. Games without a usable `.exe` keep
        // the placeholder during import and transition once at
        // reload (placeholder -> title screen). Games with an
        // `.exe` still surface the icon as soon as the `.exe`
        // entry is processed, and that surface matches what the
        // post-import scan picks - one transition, no flash.
        //
        // `Game.exe` is the canonical RPG Maker default and wins
        // outright when present; other qualifying `.exe`s set a
        // tentative sidecar that `Game.exe` can still overwrite
        // if it arrives later in archive order. Utility binaries
        // (patchers, launchers, unins000.exe, etc.) are skipped
        // wholesale via the keyword blocklist.
        //
        // Sidecar lives at `<container>/Metadata/exe-icon.png`,
        // not inside `Game/`, so the imported game tree stays
        // untouched and the file survives the tmp->destination
        // move unchanged.
        let exeArtworkLocked = Mutex(false)
        let hasTentativeExeArtwork = Mutex(false)
        do {
            try ArchiveExtractor.extract(
                archive: sourceURL,
                to: tmpDir,
                shouldCancel: { self.isImportCancelled(importID) },
                progress: { _, pct in
                    self.updateCardProgress(importID, pct)
                },
                onFileWritten: { relative, diskURL in
                    let lower = relative.lowercased()
                    let filename = (relative as NSString).lastPathComponent

                    // Only react to root-level executables (depth
                    // 0 or 1, matching the archive's optional
                    // wrapper folder).
                    guard lower.hasSuffix(".exe") else { return }
                    let components = lower.split(separator: "/", omittingEmptySubsequences: false)
                    let depth = components.count - 1
                    guard depth <= 1 else { return }
                    if exeArtworkLocked.withLock({ $0 }) { return }

                    let isGameExe = filename.lowercased() == "game.exe"
                    if !isGameExe, ExecutableIconExtractor.isUtilityExecutable(filename: filename) {
                        return
                    }
                    // Non-canonical binaries defer to any
                    // previously-written tentative sidecar; only
                    // `Game.exe` overwrites.
                    if !isGameExe, hasTentativeExeArtwork.withLock({ $0 }) { return }

                    guard let data = try? Data(contentsOf: diskURL, options: .mappedIfSafe) else {
                        return
                    }
                    guard let pe = PEImage(data: data),
                        let image = pe.extractIcon(),
                        let png = image.pngData()
                    else {
                        return
                    }

                    container.ensureMetadataDirectory()
                    let sidecarURL = container.exeIconSidecarURL
                    do {
                        try png.write(to: sidecarURL)
                    } catch {
                        NSLog("[GameLibrary] Sidecar write failed: %@", "\(error)")
                        return
                    }
                    ImageCache.shared.evict(path: sidecarURL.path)
                    _ = ImageCache.shared.image(for: sidecarURL.path)

                    hasTentativeExeArtwork.withLock { $0 = true }
                    if isGameExe {
                        exeArtworkLocked.withLock { $0 = true }
                    }
                    self.updateCardArtwork(importID, artworkPath: sidecarURL.path)
                }
            )
        } catch ArchiveExtractor.Error.cancelled {
            throw ImportCancelled()
        }
        guard !isImportCancelled(importID) else { throw ImportCancelled() }

        let gameRoot = try {
            if let preferredGameRootRelativePath {
                return try GameImportValidator.resolveGameRoot(
                    in: tmpDir,
                    relativePath: preferredGameRootRelativePath
                )
            }
            return GameImportValidator.locateGameRoot(in: tmpDir) ?? GameContainer.findGameRoot(in: tmpDir)
        }()

        // JGP post-processing: if the archive was a JoiPlay .jgp,
        // parse manifest/configuration/gamepad, reject unsupported
        // runtimes, strip the JGP-specific files from the game
        // folder so they don't ship next to the engine files, and
        // keep a `JgpImport` bundle so we can seed metadata +
        // settings after the final move. Regular .zip imports skip
        // this branch entirely.
        let jgpBundle: Jgp.Bundle? =
            sourceURL.pathExtension.lowercased() == "jgp"
            ? try GameImporter.preprocessJgp(at: gameRoot)
            : nil

        // Move the extracted tree into <container>/Game/. The
        // exe-icon sidecar (if written above) already lives at
        // <container>/Metadata/exe-icon.png and survives this move
        // unchanged because Metadata/ is a sibling of Game/.
        try fm.createDirectory(at: container.url, withIntermediateDirectories: true)
        try fm.moveItem(at: gameRoot, to: container.gameURL)

        if isImportCancelled(importID) { throw ImportCancelled() }
        if let bundle = jgpBundle {
            GameImporter.finalizeJgpImport(
                container: container,
                bundle: bundle
            )
        } else {
            GameImporter.createMetadata(in: container)
        }
        committed = true
    }

    func deleteGame(_ entry: GameEntry, onError: (@MainActor @Sendable (String) -> Void)? = nil) {
        if entry.isImporting {
            cancelImport(entry.id)
            abandonImport(importID: entry.id, container: entry.container)
            return
        }

        let container = entry.container
        removeLibraryEntry(id: entry.id)
        Self.deleteContainer(container, onError: onError)
    }
}
