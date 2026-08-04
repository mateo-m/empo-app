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
    let iconPNG: Data?

    init(relativePath: String, displayName: String, iconPNG: Data? = nil) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.iconPNG = iconPNG
    }

    init(choice: GameImportValidator.ImportRootChoice) {
        self.init(
            relativePath: choice.relativePath,
            displayName: choice.title,
            iconPNG: choice.artwork?.iconData
        )
    }
}

struct ImportRootPrompt: Identifiable {
    let request: QueuedImportRequest
    let choices: [GameImportValidator.ImportRootChoice]
    /// Choice ids whose sanitized title matches an installed game:
    /// importing them updates that install in place. Drives the
    /// picker's "Already in Library" step. Advisory for display only -
    /// `planImports` re-checks at confirm time.
    let updatingChoiceIDs: Set<String>

    var id: UUID { request.id }
}

/// An import selection resolved to its destination folder name (the
/// sanitized game title), plus the installed container it would
/// replace when that name is already taken.
struct PlannedImport: Hashable, Sendable {
    let selection: ImportSelection
    let folderName: String
    let replacing: GameContainer?
}

/// Update-confirmation alert state. Only the single-choice import
/// path reaches it (an archive or folder with exactly one game
/// that matches an installed one) - multi-game sources confirm
/// updates inside the root picker's "Already in Library" step instead.
/// The alert also serves as the fallback when a game's installed
/// status changed while the picker was open (`updatesApprovedFor`
/// in `launchImports`).
struct ImportReplacePrompt: Identifiable {
    let requestID: UUID
    let titles: [String]

    var id: UUID { requestID }
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
        case awaitingChoice(
            [GameImportValidator.ImportRootChoice],
            updatingChoiceIDs: Set<String>
        )
        /// `approvedUpdateIDs` carries the choice ids (relative
        /// paths) the user already approved in the picker's Update
        /// step - the alert asks only about the others, and
        /// declining drops only the others.
        case awaitingReplaceConfirmation([PlannedImport], approvedUpdateIDs: Set<String>)
        case launching
    }

    let request: QueuedImportRequest
    var preparedSource: ImportPreparedSource?
    var probeInventory: ArchiveExtractor.Inventory?
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
        guard case .awaitingChoice(let choices, let updatingChoiceIDs) = currentSession.state
        else { return nil }
        return ImportRootPrompt(
            request: currentSession.request,
            choices: choices,
            updatingChoiceIDs: updatingChoiceIDs
        )
    }

    var activeReplacePrompt: ImportReplacePrompt? {
        guard let currentSession else { return nil }
        guard
            case .awaitingReplaceConfirmation(let plans, let approvedUpdateIDs) =
                currentSession.state
        else {
            return nil
        }
        // Ask only about updates the user has NOT already approved
        // in the picker's Update step.
        return ImportReplacePrompt(
            requestID: currentSession.request.id,
            titles: plans.compactMap { plan in
                guard plan.replacing != nil,
                    !approvedUpdateIDs.contains(plan.selection.relativePath)
                else { return nil }
                return plan.folderName
            }
        )
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

    /// Picker confirmation. `approvedUpdateIDs` is the subset of
    /// choice ids the user explicitly selected in the picker's
    /// "Already in Library" step - updates among them proceed without a
    /// second confirmation.
    func confirmChoice(
        _ choices: [GameImportValidator.ImportRootChoice],
        approvedUpdateIDs: Set<String>
    ) {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        launchImports(
            choices.map(ImportSelection.init(choice:)),
            for: currentSession.request.id,
            updatesApprovedFor: approvedUpdateIDs
        )
    }

    /// Replace-confirmation dismissed without an explicit button
    /// (swipe / tap outside). Same outcome as declining.
    func dismissReplacePrompt() {
        cancelReplace()
    }

    /// User confirmed updating the installed game(s) in place:
    /// every planned selection proceeds, replacements included.
    func confirmReplace() {
        guard let currentSession else { return }
        guard case .awaitingReplaceConfirmation(let plans, _) = currentSession.state else {
            return
        }
        proceed(with: plans, for: currentSession.request.id)
    }

    /// User declined: only the UNAPPROVED conflicting selections
    /// are dropped. Fresh selections and updates the user already
    /// approved in the picker's Update step still import.
    func cancelReplace() {
        guard let currentSession else { return }
        guard
            case .awaitingReplaceConfirmation(let plans, let approvedUpdateIDs) =
                currentSession.state
        else {
            return
        }

        let remaining = plans.filter { plan in
            plan.replacing == nil
                || approvedUpdateIDs.contains(plan.selection.relativePath)
        }
        guard !remaining.isEmpty else {
            currentSession.preparedSource?.cleanup()
            self.currentSession = nil
            startNextResolutionIfPossible()
            return
        }
        proceed(with: remaining, for: currentSession.request.id)
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

                let probeResult = try await ImportPipelineService.probeChoices(for: preparedSource)
                guard isCurrentSession(request.id) else {
                    preparedSource.cleanup()
                    return
                }

                currentSession?.probeInventory = probeResult.inventory
                let choices = probeResult.choices

                if choices.count > 1 {
                    currentSession?.state = .awaitingChoice(
                        choices,
                        updatingChoiceIDs: Self.updatingChoiceIDs(for: choices)
                    )
                    resolutionTask = nil
                } else {
                    launchImports(
                        choices.map(ImportSelection.init(choice:)),
                        for: request.id,
                        updatesApprovedFor: []
                    )
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

    /// Choices whose sanitized title matches an installed game.
    /// Display classification for the picker's "Already in Library" step;
    /// `planImports` re-derives the authoritative answer at confirm
    /// time.
    private static func updatingChoiceIDs(
        for choices: [GameImportValidator.ImportRootChoice]
    ) -> Set<String> {
        let installedNames = Set(
            GameContainer.discover().map { $0.folderName.lowercased() }
        )
        let updating = choices.filter { choice in
            installedNames.contains(GameFolderName.sanitize(choice.title).lowercased())
        }
        return Set(updating.map(\.id))
    }

    /// `updatesApprovedFor` carries the choice ids the user already
    /// approved as in-place updates in the picker. A conflicting
    /// plan outside that set (single-choice sources, or a game
    /// whose installed status changed while the picker was open)
    /// still raises the confirmation alert.
    private func launchImports(
        _ selections: [ImportSelection],
        for requestID: UUID,
        updatesApprovedFor approvedUpdateIDs: Set<String>
    ) {
        guard var currentSession else { return }
        guard currentSession.request.id == requestID else { return }
        guard currentSession.preparedSource != nil else {
            self.currentSession = nil
            resolutionTask = nil
            startNextResolutionIfPossible()
            return
        }

        let plans = planImports(selections)

        let needsConfirmation = plans.contains { plan in
            plan.replacing != nil
                && !approvedUpdateIDs.contains(plan.selection.relativePath)
        }
        if needsConfirmation {
            currentSession.state = .awaitingReplaceConfirmation(
                plans, approvedUpdateIDs: approvedUpdateIDs)
            self.currentSession = currentSession
            resolutionTask = nil
            return
        }

        proceed(with: plans, for: requestID)
    }

    /// Resolve each selection to its destination folder name (the
    /// sanitized game title from the import probe).
    ///
    /// The library invariant is **one container per title** - some
    /// games derive their data locations from the title in their
    /// INI, so a suffixed duplicate (`Testing 2`) would still call
    /// itself "Testing" and read the other copy's data. Suffixed
    /// names are therefore never minted; every collision resolves
    /// to an update or a refusal:
    ///
    ///   - A name owned by another **in-flight** import is refused
    ///     with an alert: the user almost certainly re-imported the
    ///     same game while its first import is still running.
    ///   - An exact match with an **installed** game becomes an
    ///     update-in-place plan, which the user must confirm. A
    ///     match with the currently open (playing/paused) game is
    ///     dropped outright: the engine holds its files.
    ///   - A second selection with the same title inside one batch
    ///     is refused with an alert.
    ///   - Anything else is a fresh install under the title itself.
    private func planImports(_ selections: [ImportSelection]) -> [PlannedImport] {
        // A container mid-deletion is still on disk (the delete
        // runs detached and can take seconds on a large game).
        // Planning against it would race the running rm -rf: the
        // update path could finalize a replacement that the
        // pending removeItem then unlinks. Treat those names as
        // in-flight instead - the user retries once the delete
        // lands.
        let deleting = GameLibrary.shared.deletionsInFlight.withLock { $0 }
        let installed = GameContainer.discover().filter { !deleting.contains($0.id) }
        let installedByName = Dictionary(
            installed.map { ($0.folderName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var inFlightNames: [String] = Array(deleting)
        if let library {
            inFlightNames.append(contentsOf: library.pendingImports.keys)
            for entry in library.games where entry.isImporting {
                inFlightNames.append(entry.id)
            }
        }

        let context = ImportNameResolution.Context(
            installedFolderNames: installed.map(\.folderName),
            inFlightNames: inFlightNames,
            openGameName: PauseManager.shared.pausedGame?.id ?? AppState.shared.selectedGame?.id
        )

        var reservedBatchKeys = Set<String>()
        var plans: [PlannedImport] = []
        for selection in selections {
            let outcome = ImportNameResolution.resolve(
                title: selection.displayName,
                context: context,
                reservedBatchKeys: &reservedBatchKeys
            )
            switch outcome {
            case .fresh(let folderName):
                plans.append(
                    PlannedImport(
                        selection: selection,
                        folderName: folderName,
                        replacing: nil
                    ))

            case .update(let installedFolderName):
                // An update adopts the installed container wholesale
                // (same folder name, same id, even if the new title
                // differs in case), so saves, settings, and metadata
                // stay attached.
                plans.append(
                    PlannedImport(
                        selection: selection,
                        folderName: installedFolderName,
                        replacing: installedByName[installedFolderName]
                    ))

            case .refusedInFlight:
                NSLog(
                    "[ImportPipeline] Refusing import of %@: an import with that name is in flight",
                    selection.displayName)
                presentError(
                    title: "Couldn't import \(quoted(selection.displayName))",
                    message: "This game is already being imported. "
                        + "Wait for the current import to finish, then try again."
                )

            case .refusedDuplicateInBatch:
                NSLog(
                    "[ImportPipeline] Refusing import of %@: duplicate title in batch",
                    selection.displayName)
                presentError(
                    title: "Couldn't import \(quoted(selection.displayName))",
                    message: "Another game in this import has the same title, "
                        + "so only one of them can be imported."
                )

            case .refusedOpenGame:
                NSLog(
                    "[ImportPipeline] Dropping import of %@: it would replace the open game",
                    selection.displayName)
                presentError(
                    title: "Couldn't import \(quoted(selection.displayName))",
                    message:
                        "This game is currently open. Close it from the app switcher and import again."
                )
            }
        }
        return plans
    }

    private func proceed(with plans: [PlannedImport], for requestID: UUID) {
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

        // Confirmed replacements: swap the old entry for the import
        // progress card (same id). The on-disk container stays; the
        // import task merges the new files into it at move time.
        if let library {
            for plan in plans {
                if let replaced = plan.replacing {
                    library.removeLibraryEntry(id: replaced.id)
                }
            }
        }

        startImports(
            from: preparedSource,
            archiveName: currentSession.request.archiveName,
            inventory: currentSession.probeInventory,
            plans: plans
        )

        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    private func startImports(
        from preparedSource: ImportPreparedSource,
        archiveName: String,
        inventory: ArchiveExtractor.Inventory?,
        plans: [PlannedImport]
    ) {
        guard !plans.isEmpty else {
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

        let isArchive = ArchiveExtractor.Format(extension: preparedSource.workingURL.pathExtension) != nil
        let batchSelections = plans.map { plan in
            GameLibrary.BatchSelection(
                importID: plan.folderName,
                relativePath: plan.selection.relativePath,
                displayName: plan.selection.displayName,
                iconPNG: plan.selection.iconPNG,
                replacing: plan.replacing
            )
        }

        let accessing = preparedSource.workingURL.startAccessingSecurityScopedResource()

        library.pipelineImportGames(
            from: preparedSource.workingURL,
            isArchive: isArchive,
            sourceName: archiveName,
            inventory: inventory,
            selections: batchSelections
        ) { failures in
            if accessing { preparedSource.workingURL.stopAccessingSecurityScopedResource() }
            preparedSource.cleanup()

            let succeeded = batchSelections.count - failures.count
            if succeeded > 0 {
                Haptics.impact()
            }
            let surfacedFailures = failures.filter { !($0.1 is GameLibrary.ImportCancelled) }
            if let first = surfacedFailures.first {
                self.presentError(
                    title: "Couldn't import \(quoted(archiveName))",
                    message: first.1.localizedDescription
                )
                for extra in surfacedFailures.dropFirst() {
                    NSLog(
                        "[ImportPipeline] Additional import failure: %@",
                        extra.1.localizedDescription
                    )
                }
            }
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
        // One batch can refuse several selections in one pass. A
        // plain overwrite would surface only the last refusal, so
        // later errors fold into the pending alert instead.
        guard let existing = alert else {
            alert = ImportPipelineAlert(title: title, message: message)
            return
        }
        let mergedTitle = "Some imports failed"
        let existingBody =
            existing.title == mergedTitle
            ? existing.message
            : "\(existing.title): \(existing.message)"
        alert = ImportPipelineAlert(
            title: mergedTitle,
            message: "\(existingBody)\n\n\(title): \(message)"
        )
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
    ) async throws -> GameImportValidator.ArchiveProbeResult {
        try await Task(priority: .userInitiated) {
            try probeChoicesSync(for: preparedSource)
        }
        .value
    }

    private static func prepareSourceSync(for request: QueuedImportRequest) throws -> ImportPreparedSource {
        try ImportSignpost.interval("stage-source", id: request.id.uuidString) {
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

            do {
                try fm.moveItem(at: url, to: archiveCopyURL)
            } catch {
                try fm.copyItem(at: url, to: archiveCopyURL)
            }
            copied = true

            return ImportPreparedSource(
                workingURL: archiveCopyURL, cleanupDirectoryURL: archiveCopyDirectoryURL)
        }
    }

    private static func probeChoicesSync(
        for preparedSource: ImportPreparedSource
    ) throws -> GameImportValidator.ArchiveProbeResult {
        try ImportSignpost.interval("probe", id: preparedSource.workingURL.lastPathComponent) {
            let url = preparedSource.workingURL
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            return try GameImportValidator.importRootChoices(for: url)
        }
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

    /// One game to import. `importID` is the destination folder
    /// name under `Games/` (the sanitized game title), which is
    /// also the container id and the progress-card id. `replacing`
    /// carries the installed container the user agreed to update:
    /// the import merges the new files into its `Game/` tree,
    /// overwriting same-path files and keeping everything else.
    struct BatchSelection: Sendable {
        let importID: String
        let relativePath: String
        let displayName: String
        let iconPNG: Data?
        let replacing: GameContainer?

        init(
            importID: String,
            relativePath: String,
            displayName: String,
            iconPNG: Data?,
            replacing: GameContainer? = nil
        ) {
            self.importID = importID
            self.relativePath = relativePath
            self.displayName = displayName
            self.iconPNG = iconPNG
            self.replacing = replacing
        }
    }

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
    ///
    /// Replacements (see `replacingImports`) never delete: the
    /// container is the installed game, holding the user's saves
    /// and settings - and thanks to the staged, atomic swap in
    /// `stageAndSwapGameTree`, still exactly the pre-update files.
    /// Its entry is re-surfaced instead.
    @MainActor
    func abandonImport(importID: String, container: GameContainer?) {
        // Idempotence guard: the delete-an-importing-card path and
        // the import task's own failure path both land here. The
        // second call must be a no-op - after the first one
        // consumed the replacement marker, a repeat would resolve
        // the INSTALLED container from disk and delete it.
        let hadPendingImport = pendingImports.removeValue(forKey: importID) != nil
        let entry = games.first(where: { $0.id == importID })
        guard hadPendingImport || entry?.isImporting == true else { return }

        let resolvedContainer =
            container ?? entry?.container ?? Self.containerOnDisk(importID: importID)
        removeLibraryEntry(id: importID)

        // Consume (not just read) the marker: this hop owns it for
        // failed selections; `finishBatch` only clears markers of
        // selections that succeeded.
        let isReplacement = replacingImports.withLock { $0.remove(importID) != nil }
        if isReplacement {
            if let resolvedContainer {
                mergeImportedGame(container: resolvedContainer)
            }
            return
        }
        Self.deleteContainer(resolvedContainer)
    }

    /// Flip an entry into the inert `.deleting` state. The card
    /// stays visible with a spinner while the rescue + delete run;
    /// `removeLibraryEntry` (success) or
    /// `restoreEntryAfterFailedDelete` (failure) resolves it.
    @MainActor
    func markEntryDeleting(id: String) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        localMutationDates[id] = Date()
        withAnimation {
            games[index].status = .deleting
        }
    }

    /// The delete did not happen (failed rescue, or an error): the
    /// game is still installed, so its card goes back to ready.
    @MainActor
    func restoreEntryAfterFailedDelete(id: String) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        localMutationDates[id] = Date()
        withAnimation {
            games[index].status = .ready
        }
    }

    /// Remove a library card from memory (artwork cache + `games`).
    @MainActor
    func removeLibraryEntry(id: String) {
        if let artworkPath = games.first(where: { $0.id == id })?.artworkPath {
            // The source files are being deleted, so the disk sweep
            // can run off-main (see `DiskSweep`). Bulk deletes call
            // this once per game; a synchronous walk here would put
            // O(games x cache entries) disk I/O on the main actor.
            ImageCache.shared.evict(path: artworkPath, diskSweep: .background)
        }
        // Stamped so a scan that snapshotted this entry BEFORE the
        // removal cannot append it back as a ghost card
        // (`applyScanResults` compares against its start date).
        localMutationDates[id] = Date()
        withAnimation {
            games.removeAll { $0.id == id }
        }
    }

    nonisolated static func containerOnDisk(importID: String) -> GameContainer? {
        GameContainer.discover().first { $0.id == importID }
    }

    /// Recursively delete a game container. `onError` is set for
    /// user-initiated deletes. Import abandon passes nil so a
    /// failed cleanup stays silent. `rescueSaves` is set for
    /// user-initiated deletes only: a legacy `UserData/` drains
    /// into the shared `Documents/Data/` tree and portable saves
    /// move into `Rescued Saves/` before the tree goes away - and
    /// a failed rescue ABORTS the delete instead of erasing the
    /// only copy of the saves.
    private enum DeleteOutcome {
        case finished
        case rescueFailed
        case failed(String)
    }

    nonisolated static func deleteContainer(
        _ container: GameContainer?,
        rescueSaves: Bool = false,
        onError: (@MainActor @Sendable (String) -> Void)? = nil,
        onRescueFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let container else { return }
        Task.detached(priority: .userInitiated) {
            let outcome = Self.performDelete(container, rescueSaves: rescueSaves)
            // Release BEFORE any restore reload runs: the reload's
            // scan consults `deletionsInFlight` live, and an id
            // still registered would make the scan skip the very
            // container the reload exists to bring back - the kept
            // game would then stay missing from the library until
            // some unrelated reload. (The id joined the set on the
            // main actor before this task started, user-initiated
            // deletes only; removing an unregistered id is a
            // no-op.)
            await MainActor.run {
                GameLibrary.shared.deletionsInFlight.withLock {
                    _ = $0.remove(container.id)
                }
                switch outcome {
                case .finished:
                    GameLibrary.shared.removeLibraryEntry(id: container.id)
                case .rescueFailed:
                    GameLibrary.shared.restoreEntryAfterFailedDelete(id: container.id)
                    GameLibrary.shared.reload()
                    if let onRescueFailure {
                        onRescueFailure()
                    } else {
                        onError?(
                            "Empo could not rescue this game's saves. "
                                + "The game was not deleted.")
                    }
                case .failed(let message):
                    GameLibrary.shared.restoreEntryAfterFailedDelete(id: container.id)
                    GameLibrary.shared.reload()
                    onError?(message)
                }
            }
        }
    }

    private nonisolated static func performDelete(
        _ container: GameContainer,
        rescueSaves: Bool
    ) -> DeleteOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: container.url.path) else { return .finished }

        if rescueSaves, !DataDirectory.rescueUserDataBeforeDeletion(of: container) {
            // Abort and let the UI offer the choice (keep the game,
            // or delete anyway with eyes open). Deleting here would
            // erase the only copy of the saves right after the
            // delete alert promised they survive.
            NSLog(
                "[GameLibrary] Rescue of UserData failed for %@; delete aborted",
                container.folderName)
            return .rescueFailed
        }

        do {
            // One rm -rf removes Game/, EmpoState/, Logs/, and
            // Metadata/ together. Per-game settings, logs, custom
            // artwork, and crash markers all go in a single call.
            // Saves live in Documents/Data/ (or, rescued, in
            // Documents/Rescued Saves/) and stay.
            try container.deleteAll()
        } catch {
            NSLog("[GameLibrary] Delete error: %@", "\(error)")
            // A concurrent remover (the scan's cleanup of the same
            // container) can win the race and make our own pass
            // throw on a tree that is in fact gone. That is a
            // successful delete, not an error to alert about.
            guard fm.fileExists(atPath: container.url.path) else { return .finished }
            return .failed(error.localizedDescription)
        }
        return .finished
    }

    func pipelineImportGames(
        from sourceURL: URL,
        isArchive: Bool,
        sourceName: String,
        inventory: ArchiveExtractor.Inventory?,
        selections: [GameLibrary.BatchSelection],
        completion: @escaping @MainActor @Sendable (_ failures: [(GameLibrary.BatchSelection, Error)]) -> Void
    ) {
        ensureGamesDirectory()

        for selection in selections {
            let pendingOrder = nextPendingImportOrder
            nextPendingImportOrder += 1
            pendingImports[selection.importID] = PendingImport(
                id: selection.importID,
                displayName: selection.displayName,
                order: pendingOrder
            )
            inFlightImports.withLock { _ = $0.insert(selection.importID) }
            if selection.replacing != nil {
                replacingImports.withLock { _ = $0.insert(selection.importID) }
            }
        }

        let batchID = UUID().uuidString
        Task.detached(priority: .userInitiated) {
            defer {
                for selection in selections {
                    self.clearCancellation(selection.importID)
                }
            }

            var active = selections
            var failures: [(GameLibrary.BatchSelection, Error)] = []
            var containers: [String: GameContainer] = [:]
            var surfacers: [String: ExeIconSurfacer] = [:]
            let fm = FileManager.default

            func failSelection(_ sel: GameLibrary.BatchSelection, _ error: Error) {
                failures.append((sel, error))
                active.removeAll { $0.importID == sel.importID }
                self.inFlightImports.withLock { _ = $0.remove(sel.importID) }
                Task { @MainActor in
                    GameLibrary.shared.abandonImport(
                        importID: sel.importID, container: containers[sel.importID])
                }
            }

            func checkCancellations() {
                let cancelled = active.filter { self.isImportCancelled($0.importID) }
                for sel in cancelled {
                    failSelection(sel, ImportCancelled())
                }
            }

            func writeProbeIconSidecar(_ iconPNG: Data?, to container: GameContainer) -> String? {
                guard let iconPNG else { return nil }
                container.ensureMetadataDirectory()
                let sidecarURL = container.exeIconSidecarURL
                guard (try? iconPNG.write(to: sidecarURL)) != nil else { return nil }
                return sidecarURL.path
            }

            func resolveRoot(in baseURL: URL, relativePath: String) throws -> URL {
                if relativePath.isEmpty {
                    return GameImportValidator.locateGameRoot(in: baseURL)
                        ?? GameContainer.findGameRoot(in: baseURL)
                }
                return try GameImportValidator.resolveGameRoot(in: baseURL, relativePath: relativePath)
            }

            func failAllActive(_ error: Error) {
                for sel in active {
                    failSelection(sel, error)
                }
            }

            // Batch epilogue on the main actor. Clears the
            // replacement markers of SUCCESSFUL selections only.
            // Each failed selection's marker belongs to its
            // abandonImport hop, which consumes it - actors do not
            // guarantee FIFO between independently enqueued jobs,
            // so clearing a failed selection's marker here could
            // run before its abandon hop and turn a re-surface
            // into a container deletion.
            func finishBatch(_ failures: [(GameLibrary.BatchSelection, Error)]) async {
                let failedIDs = Set(failures.map { $0.0.importID })
                await MainActor.run {
                    for selection in selections where !failedIDs.contains(selection.importID) {
                        self.replacingImports.withLock { _ = $0.remove(selection.importID) }
                    }
                    completion(failures)
                }
            }

            do {
                checkCancellations()
                guard !active.isEmpty else {
                    await finishBatch(failures)
                    return
                }

                let tmpDir = try ImportTemporaryDirectory.makeScopedDirectory(
                    kind: isArchive ? .archiveImport : .folderImport,
                    fm: fm
                )
                defer { try? fm.removeItem(at: tmpDir) }

                let stagedBaseURL: URL
                if isArchive {
                    for sel in active {
                        let container = GameContainer(folderName: sel.importID)
                        containers[sel.importID] = container
                        let artworkPath = writeProbeIconSidecar(sel.iconPNG, to: container)
                        self.commitPendingToCard(
                            sel.importID,
                            container: container,
                            title: sel.displayName,
                            artworkPath: artworkPath
                        )
                        surfacers[sel.importID] = ExeIconSurfacer(container: container) { path in
                            self.updateCardArtwork(sel.importID, artworkPath: path)
                        }
                    }

                    try ImportSignpost.interval("extract", id: batchID) {
                        try ArchiveExtractor.extract(
                            archive: sourceURL,
                            to: tmpDir,
                            shouldCancel: {
                                checkCancellations()
                                return active.isEmpty
                                    || active.allSatisfy { self.isImportCancelled($0.importID) }
                            },
                            inventory: inventory,
                            progress: { _, pct in
                                checkCancellations()
                                let scaled = pct * 0.95
                                for sel in active {
                                    self.updateCardProgress(sel.importID, scaled)
                                }
                            },
                            onFileWritten: { relative, diskURL in
                                guard relative.lowercased().hasSuffix(".exe") else { return }
                                let filename = (relative as NSString).lastPathComponent
                                guard let sel = Self.matchingSelection(for: relative, in: active) else {
                                    return
                                }
                                guard
                                    Self.isRootLevelExe(
                                        relativePath: relative, selectionRoot: sel.relativePath)
                                else {
                                    return
                                }
                                surfacers[sel.importID]?.offer(fileURL: diskURL, filename: filename)
                            }
                        )
                    }

                    for surfacer in surfacers.values {
                        surfacer.drain()
                    }
                    stagedBaseURL = tmpDir
                } else {
                    let folderName = sourceURL.lastPathComponent
                    let tmpDest = tmpDir.appendingPathComponent(folderName)

                    try ImportSignpost.interval("stage-source", id: batchID) {
                        do {
                            try fm.moveItem(at: sourceURL, to: tmpDest)
                        } catch {
                            try fm.copyItem(at: sourceURL, to: tmpDest)
                        }
                    }

                    try ImportSignpost.interval("validate", id: batchID) {
                        try GameImportValidator.validate(tmpDest)
                    }
                    checkCancellations()
                    guard !active.isEmpty else {
                        await finishBatch(failures)
                        return
                    }

                    for sel in active {
                        let container = GameContainer(folderName: sel.importID)
                        containers[sel.importID] = container

                        let root: URL
                        do {
                            root = try resolveRoot(in: tmpDest, relativePath: sel.relativePath)
                        } catch {
                            failSelection(sel, error)
                            continue
                        }

                        var artworkPath = GameCatalog.findFolderImportArtwork(at: root)
                        if artworkPath == nil {
                            artworkPath = writeProbeIconSidecar(sel.iconPNG, to: container)
                        }
                        if let path = artworkPath {
                            ImageCache.shared.prewarmThumbnail(
                                for: path, maxPixelSize: ImageCache.PixelBudget.cell)
                        }
                        self.commitPendingToCard(
                            sel.importID,
                            container: container,
                            title: sel.displayName,
                            artworkPath: artworkPath
                        )
                        self.updateCardProgress(sel.importID, 0.5)
                    }
                    stagedBaseURL = tmpDest
                }

                checkCancellations()
                let moveOrder = active.sorted {
                    $0.relativePath.split(separator: "/").count
                        > $1.relativePath.split(separator: "/").count
                }

                for sel in moveOrder {
                    checkCancellations()
                    guard active.contains(where: { $0.importID == sel.importID }) else { continue }
                    guard let container = containers[sel.importID] else { continue }
                    let isReplacement = sel.replacing != nil
                    // A genuine prior install finalized its import
                    // and wrote metadata.json. Without it, the
                    // "installed game" being updated is a broken
                    // remnant (invalid card, crash orphan) - then
                    // finalize must run the fresh seeding path so
                    // settings and metadata exist, instead of
                    // preserving state that was never written.
                    let preserveExistingState =
                        isReplacement
                        && fm.fileExists(atPath: container.metadataJSONURL.path)

                    // Cleanup only ever removes a directory THIS
                    // import created. A pre-existing item at the
                    // container path (a stray file the user put in
                    // Games/, a container discovery missed) is not
                    // ours to delete, no matter how the import
                    // ends.
                    let containerExisted = fm.fileExists(atPath: container.url.path)
                    var committed = false
                    defer {
                        // Fresh imports only: a failed replacement
                        // must never delete the container - it IS
                        // the installed game, saves included. Its
                        // entry is re-surfaced by abandonImport.
                        if !committed && !isReplacement && !containerExisted {
                            try? container.deleteAll()
                        }
                    }

                    let gameRoot: URL
                    do {
                        gameRoot = try resolveRoot(in: stagedBaseURL, relativePath: sel.relativePath)
                    } catch {
                        failSelection(sel, error)
                        continue
                    }

                    let jgpBundle: Jgp.Bundle?
                    if sourceURL.pathExtension.lowercased() == "jgp" {
                        do {
                            jgpBundle = try GameImporter.preprocessJgp(at: gameRoot)
                        } catch {
                            failSelection(sel, error)
                            continue
                        }
                    } else {
                        jgpBundle = nil
                    }

                    do {
                        try ImportSignpost.interval("move", id: sel.importID) {
                            try fm.createDirectory(
                                at: container.url,
                                withIntermediateDirectories: true
                            )
                            if isReplacement {
                                // A crashed earlier update can have
                                // left `Game/` displaced into the
                                // staging/backup artifacts. Restore
                                // it BEFORE branching on existence:
                                // the plain-move branch below would
                                // otherwise drop the new tree next
                                // to artifacts holding the only
                                // copies of the old one.
                                _ = GameTreeUpdate.sweepInterruptedUpdate(
                                    target: container.gameURL, fm: fm)
                            }
                            if isReplacement, fm.fileExists(atPath: container.gameURL.path) {
                                // Update in place, transactionally:
                                // the new files merge into a staging
                                // clone (same-path files overwritten,
                                // everything else kept - saves beside
                                // the game files, mods, assets the new
                                // version doesn't ship), then the
                                // staging tree swaps in atomically.
                                // Any failure leaves the installed
                                // Game/ untouched.
                                try GameImporter.stageAndSwapGameTree(
                                    newTree: gameRoot, over: container.gameURL, fm: fm)
                            } else {
                                try fm.moveItem(at: gameRoot, to: container.gameURL)
                            }
                            GameContainer.normalizeImportedGamePermissions(at: container.gameURL)
                        }
                    } catch {
                        let surfaced: Error = Self.isOutOfSpace(error) ? ImportError.outOfSpace : error
                        failSelection(sel, surfaced)
                        continue
                    }

                    // Replacements are past the point of no return
                    // here: the swap already applied the new files.
                    // Honoring a late cancel would skip finalize and
                    // leave a stale script profile over the new
                    // tree, so replacements run finalize regardless.
                    if !isReplacement, self.isImportCancelled(sel.importID) {
                        failSelection(sel, ImportCancelled())
                        continue
                    }

                    self.updateCardProgress(sel.importID, 0.97)

                    ImportSignpost.interval("finalize", id: sel.importID) {
                        if let bundle = jgpBundle {
                            GameImporter.finalizeJgpImport(
                                container: container,
                                bundle: bundle,
                                preservingExistingState: preserveExistingState
                            )
                        } else if isArchive {
                            if !fm.fileExists(atPath: container.exeIconSidecarURL.path) {
                                _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)
                            }
                            if preserveExistingState {
                                GameImporter.refreshMetadataAfterReplacement(in: container)
                            } else {
                                GameImporter.createMetadata(in: container)
                            }
                        } else {
                            _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)
                            if preserveExistingState {
                                GameImporter.refreshMetadataAfterReplacement(in: container)
                            } else {
                                GameImporter.seedFolderImport(in: container)
                            }
                        }
                    }

                    if !isReplacement {
                        // A fresh import of a game that was deleted
                        // earlier gets its rescued portable saves
                        // back: matching `Rescued Saves/` buckets
                        // drain into the new `Game/` tree before
                        // the first launch. Updates never ran the
                        // rescue, so they have nothing to restore.
                        DataDirectory.restoreRescuedSaves(for: container)
                    }

                    committed = true
                    self.inFlightImports.withLock { _ = $0.remove(sel.importID) }
                    active.removeAll { $0.importID == sel.importID }
                    self.updateCardProgress(sel.importID, 1.0)

                    await MainActor.run {
                        GameLibrary.shared.mergeImportedGame(container: container)
                    }
                }

                await finishBatch(failures)
            } catch is ImportCancelled {
                failAllActive(ImportCancelled())
                await finishBatch(failures)
            } catch ArchiveExtractor.Error.cancelled {
                failAllActive(ImportCancelled())
                await finishBatch(failures)
            } catch {
                let surfaced: Error = Self.isOutOfSpace(error) ? ImportError.outOfSpace : error
                failAllActive(surfaced)
                await finishBatch(failures)
            }
        }
    }

    nonisolated private static func matchingSelection(
        for relativePath: String,
        in active: [GameLibrary.BatchSelection]
    ) -> GameLibrary.BatchSelection? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        var best: GameLibrary.BatchSelection?
        var bestDepth = -1
        for sel in active {
            let root = sel.relativePath.replacingOccurrences(of: "\\", with: "/").lowercased()
            if root.isEmpty {
                if bestDepth < 0 {
                    best = sel
                    bestDepth = 0
                }
                continue
            }
            if normalized == root || normalized.hasPrefix(root + "/") {
                let depth = root.split(separator: "/").count
                if depth > bestDepth {
                    best = sel
                    bestDepth = depth
                }
            }
        }
        return best
    }

    nonisolated private static func isRootLevelExe(relativePath: String, selectionRoot: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard normalized.hasSuffix(".exe") else { return false }
        let root = selectionRoot.replacingOccurrences(of: "\\", with: "/").lowercased()
        let prefix = root.isEmpty ? "" : root + "/"
        guard root.isEmpty || normalized.hasPrefix(prefix) else { return false }
        let suffix =
            root.isEmpty
            ? normalized
            : String(normalized.dropFirst(prefix.count))
        let depth = suffix.split(separator: "/", omittingEmptySubsequences: false).count - 1
        return depth >= 0 && depth <= 1
    }

    /// Commits a progress-card `GameEntry` to `games` and drops the
    /// matching pending entry. Called from the import pipeline once
    /// pre-flight validation passes. From this point on, the user
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
                        status: .importing
                    ))
            }
        }
    }

    /// Swap in the card's artwork mid-extract, once the archive
    /// has yielded a root-level `.exe` icon via `ExeIconSurfacer`.
    /// Only `.exe` icons surface mid-import. `Graphics/Titles/*`
    /// previews never do, because they would flash and then
    /// get replaced by the final artwork pick. Can fire more than
    /// once per import: the first non-utility `.exe` is a
    /// tentative pick that a later `Game.exe` supersedes and
    /// locks.
    nonisolated func updateCardArtwork(_ importID: String, artworkPath: String) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let model = lib.games.first(where: { $0.id == importID }) else { return }
            // The mid-extract sidecar sits at a fixed location
            // (`<container>/Metadata/exe-icon.png`) and gets
            // overwritten on disk when a later .exe in the archive
            // supersedes the earlier pick (e.g. Reborn1950 ships
            // [Patcher.exe (skipped), Reborn.exe, Game.exe]: Reborn
            // writes first, Game.exe overwrites). The path string is
            // unchanged across those writes, so the revision bump is
            // what tells GameArtworkView to reload the (already
            // evicted + re-prewarmed) contents.
            withAnimation {
                model.artworkPath = artworkPath
                model.artworkRevision += 1
            }
        }
    }

    /// Updates the extraction progress on the already-committed
    /// progress card (not on `pendingImports`, which was cleared
    /// once pre-flight passed). Ticks only re-render the card
    /// bodies that read `importProgress`, not the library. The
    /// monotonic guard matters twice over: unstructured tasks give
    /// no FIFO guarantee onto the main actor (an out-of-order write
    /// would snap the ring backwards), and the extractor degenerates
    /// to one callback per entry once its byte-based percentage
    /// saturates — those arrive as equal values and are dropped
    /// here instead of notifying observers.
    ///
    /// Strictly an UPDATE: an entry that is not currently importing
    /// stays untouched. A cancelled replacement re-surfaces the
    /// installed game's ready card while the import task keeps
    /// running (replacements finish once past the swap); a late
    /// progress hop flipping that card back to importing would
    /// re-arm the stop button - and a second stop tap would delete
    /// the installed game through the abandon path, whose
    /// replacement marker the first tap already consumed.
    nonisolated func updateCardProgress(_ importID: String, _ progress: Double) {
        Task { @MainActor in
            guard
                let model = GameLibrary.shared.games.first(where: { $0.id == importID }),
                model.isImporting
            else { return }
            guard progress > model.importProgress else { return }
            model.importProgress = progress
        }
    }

    /// `skipSaveRescue` is the user's explicit "Delete Anyway"
    /// choice after a failed save rescue - the confirmed
    /// destructive path. Never pass true on a first attempt.
    func deleteGame(
        _ entry: GameEntry,
        skipSaveRescue: Bool = false,
        onError: (@MainActor @Sendable (String) -> Void)? = nil,
        onSaveRescueFailure: (@MainActor @Sendable (GameEntry) -> Void)? = nil
    ) {
        // Re-resolve against live library state. The caller's entry
        // can be a snapshot from before an alert sat open (the
        // Delete Anyway flow), and the game may have started an
        // update import since - deleting under a running swap
        // would tear the container the import owns.
        let live = games.first(where: { $0.id == entry.id }) ?? entry
        if live.isImporting {
            cancelImport(live.id)
            abandonImport(importID: live.id, container: live.container)
            return
        }
        if live.isDeleting {
            // A delete for this entry is already running.
            return
        }
        let importOwnsContainer = inFlightImports.withLock { $0.contains(live.id) }
        if importOwnsContainer {
            NSLog(
                "[GameLibrary] Ignoring delete of %@: an import owns its container",
                live.id)
            return
        }

        let container = live.container
        // The card stays in place, inert, with a spinner: the
        // rescue is disk I/O of unknown duration, and the entry
        // leaves the library only when the delete really finished
        // (so a failed rescue never makes the card blink out and
        // back).
        markEntryDeleting(id: live.id)
        // Registered BEFORE the detached delete starts so
        // `planImports` sees the id the moment the entry leaves
        // the library; the delete task releases it when done.
        deletionsInFlight.withLock { _ = $0.insert(live.id) }
        Self.deleteContainer(
            container,
            rescueSaves: !skipSaveRescue,
            onError: onError,
            onRescueFailure: onSaveRescueFailure.map { handler in
                { @MainActor @Sendable in handler(live) }
            }
        )
    }
}
