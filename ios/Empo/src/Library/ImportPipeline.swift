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

/// Update-confirmation state surfaced to the library view. Lists
/// the installed games the pending import batch would update in
/// place (merge new files over the existing `Game/` tree). A single
/// conflict presents as an alert; several present as the update
/// picker sheet, where each game is individually selectable.
struct ImportReplacePrompt: Identifiable {
    struct Item: Identifiable, Hashable {
        /// Installed container name - the row title and the key
        /// `confirmReplace(updating:)` selects on.
        let folderName: String
        /// Probe icon of the *incoming* version, when it has one.
        let iconPNG: Data?

        var id: String { folderName }
    }

    let requestID: UUID
    let items: [Item]
    /// Non-conflicting selections riding in the same batch. They
    /// import in full no matter how the user answers; the copy on
    /// both surfaces says so when this is non-zero.
    let freshCount: Int

    var titles: [String] { items.map(\.folderName) }
    var id: UUID { requestID }

    /// Sentence appended to the confirmation copy when the batch
    /// also contains games that aren't installed yet. nil when the
    /// whole batch is updates.
    var unaffectedGamesSentence: String? {
        switch freshCount {
        case 0:
            return nil
        case 1:
            return "The other game in this import isn't affected and will still be added."
        default:
            return "The other \(freshCount) games in this import aren't affected and will still be added."
        }
    }
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
        case awaitingReplaceConfirmation([PlannedImport])
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
        guard case .awaitingChoice(let choices) = currentSession.state else { return nil }
        return ImportRootPrompt(request: currentSession.request, choices: choices)
    }

    var activeReplacePrompt: ImportReplacePrompt? {
        guard let currentSession else { return nil }
        guard case .awaitingReplaceConfirmation(let plans) = currentSession.state else {
            return nil
        }
        return ImportReplacePrompt(
            requestID: currentSession.request.id,
            items: plans.compactMap { plan in
                guard plan.replacing != nil else { return nil }
                return ImportReplacePrompt.Item(
                    folderName: plan.folderName,
                    iconPNG: plan.selection.iconPNG
                )
            },
            freshCount: plans.filter { $0.replacing == nil }.count
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

    func confirmChoice(_ choices: [GameImportValidator.ImportRootChoice]) {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        launchImports(
            choices.map(ImportSelection.init(choice:)),
            for: currentSession.request.id
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
        guard case .awaitingReplaceConfirmation(let plans) = currentSession.state else {
            return
        }
        proceed(with: plans, for: currentSession.request.id)
    }

    /// Update-picker confirmation: update only the chosen installed
    /// games (keyed by folder name). Unchosen conflicting
    /// selections are dropped; fresh selections in the batch always
    /// proceed.
    func confirmReplace(updating selectedFolderNames: Set<String>) {
        guard let currentSession else { return }
        guard case .awaitingReplaceConfirmation(let plans) = currentSession.state else {
            return
        }

        let remaining = plans.filter { plan in
            plan.replacing == nil || selectedFolderNames.contains(plan.folderName)
        }
        guard !remaining.isEmpty else {
            currentSession.preparedSource?.cleanup()
            self.currentSession = nil
            startNextResolutionIfPossible()
            return
        }
        proceed(with: remaining, for: currentSession.request.id)
    }

    /// User declined: the conflicting selections are dropped, any
    /// non-conflicting selections from the same batch still import.
    func cancelReplace() {
        guard let currentSession else { return }
        guard case .awaitingReplaceConfirmation(let plans) = currentSession.state else {
            return
        }

        let remaining = plans.filter { $0.replacing == nil }
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
        guard currentSession.preparedSource != nil else {
            self.currentSession = nil
            resolutionTask = nil
            startNextResolutionIfPossible()
            return
        }

        let plans = planImports(selections)

        if plans.contains(where: { $0.replacing != nil }) {
            currentSession.state = .awaitingReplaceConfirmation(plans)
            self.currentSession = currentSession
            resolutionTask = nil
            return
        }

        proceed(with: plans, for: requestID)
    }

    /// Resolve each selection to its destination folder name (the
    /// sanitized game title from the import probe).
    ///
    ///   - A name owned by another **in-flight** import is refused
    ///     with an alert: the user almost certainly re-imported the
    ///     same game while its first import is still running, and a
    ///     silently suffixed duplicate would just show two
    ///     identical-looking cards.
    ///   - An exact match with an **installed** game becomes an
    ///     update-in-place plan, which the user must confirm. A
    ///     match with the currently open (playing/paused) game is
    ///     dropped outright: the engine holds its files.
    ///   - Anything else is a fresh install. Its name dodges the
    ///     batch, in-flight imports, AND installed games with a
    ///     numbered suffix - a suffix must never silently land on
    ///     an installed game and turn into an unintended update.
    private func planImports(_ selections: [ImportSelection]) -> [PlannedImport] {
        let installedByLowercaseName = Dictionary(
            GameContainer.discover().map { ($0.folderName.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var inFlightKeys = Set<String>()
        if let library {
            inFlightKeys.formUnion(library.pendingImports.keys.map { $0.lowercased() })
            for entry in library.games where entry.isImporting {
                inFlightKeys.insert(entry.id.lowercased())
            }
        }

        let activeGameID =
            PauseManager.shared.pausedGame?.id ?? AppState.shared.selectedGame?.id

        var batchKeys = Set<String>()
        var plans: [PlannedImport] = []
        for selection in selections {
            let preferred = GameFolderName.sanitize(selection.displayName)
            let preferredKey = preferred.lowercased()

            if inFlightKeys.contains(preferredKey) {
                NSLog(
                    "[ImportPipeline] Refusing import of %@: an import with that name is in flight",
                    preferred)
                presentError(
                    title: "Couldn't import \(quoted(selection.displayName))",
                    message: "This game is already being imported. "
                        + "Wait for the current import to finish, then try again."
                )
                continue
            }

            if !batchKeys.contains(preferredKey),
                let replacing = installedByLowercaseName[preferredKey]
            {
                if replacing.id == activeGameID {
                    NSLog(
                        "[ImportPipeline] Dropping import of %@: it would replace the open game",
                        preferred)
                    presentError(
                        title: "Couldn't import \(quoted(selection.displayName))",
                        message:
                            "This game is currently open. Close it from the app switcher and import again."
                    )
                    continue
                }

                batchKeys.insert(preferredKey)
                plans.append(
                    PlannedImport(
                        selection: selection,
                        // An update adopts the installed container
                        // wholesale (same folder name, same id, even
                        // if the new title differs in case), so
                        // saves, settings, and metadata stay
                        // attached.
                        folderName: replacing.folderName,
                        replacing: replacing
                    ))
                continue
            }

            let folderName = GameFolderName.uniqueName(preferring: preferred) { candidate in
                let key = candidate.lowercased()
                return batchKeys.contains(key)
                    || inFlightKeys.contains(key)
                    || installedByLowercaseName[key] != nil
            }
            batchKeys.insert(folderName.lowercased())
            plans.append(
                PlannedImport(
                    selection: selection,
                    folderName: folderName,
                    replacing: nil
                ))
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
        alert = ImportPipelineAlert(title: title, message: message)
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
        _ = pendingImports.removeValue(forKey: importID)
        let entry = games.first(where: { $0.id == importID })
        let resolvedContainer =
            container ?? entry?.container ?? Self.containerOnDisk(importID: importID)
        removeLibraryEntry(id: importID)

        let isReplacement = replacingImports.withLock { $0.contains(importID) }
        if isReplacement {
            if let resolvedContainer {
                mergeImportedGame(container: resolvedContainer)
            }
            return
        }
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
    /// user-initiated deletes. Import abandon passes nil so a
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
                // One rm -rf removes Game/, EmpoState/, Logs/, and
                // Metadata/ together. Per-game saves, settings,
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
            // replacement markers HERE (not in the detached defer):
            // the main actor is serial, and every abandonImport hop
            // enqueued by failSelection precedes this closure, so
            // each of them still sees its marker and knows not to
            // delete the installed game.
            func finishBatch(_ failures: [(GameLibrary.BatchSelection, Error)]) async {
                await MainActor.run {
                    for selection in selections {
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
                            _ = ImageCache.shared.image(for: path)
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

                    var committed = false
                    defer {
                        // Fresh imports only: a failed replacement
                        // must never delete the container - it IS
                        // the installed game, saves included. Its
                        // entry is re-surfaced by abandonImport.
                        if !committed && !isReplacement {
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

                    if self.isImportCancelled(sel.importID) {
                        failSelection(sel, ImportCancelled())
                        continue
                    }

                    self.updateCardProgress(sel.importID, 0.97)

                    ImportSignpost.interval("finalize", id: sel.importID) {
                        if let bundle = jgpBundle {
                            GameImporter.finalizeJgpImport(
                                container: container,
                                bundle: bundle,
                                preservingExistingState: isReplacement
                            )
                        } else if isArchive {
                            if !fm.fileExists(atPath: container.exeIconSidecarURL.path) {
                                _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)
                            }
                            if isReplacement {
                                GameImporter.refreshMetadataAfterReplacement(in: container)
                            } else {
                                GameImporter.createMetadata(in: container)
                            }
                        } else {
                            _ = ExecutableIconExtractor.writeSidecarIfPossible(in: container)
                            if isReplacement {
                                GameImporter.refreshMetadataAfterReplacement(in: container)
                            } else {
                                GameImporter.seedFolderImport(in: container)
                            }
                        }
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
                        status: .importing(progress: 0)
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
    /// locks. Rebuilding the entry (rather than mutating
    /// `artworkPath` on the existing one) goes through SwiftUI's
    /// normal diffing so the card cross-fades the placeholder to
    /// the real artwork.
    nonisolated func updateCardArtwork(_ importID: String, artworkPath: String) {
        Task { @MainActor in
            let lib = GameLibrary.shared
            guard let idx = lib.games.firstIndex(where: { $0.id == importID }) else { return }
            // No early-return on same path. The mid-extract sidecar
            // is at a fixed location (`<container>/Metadata/exe-icon.png`)
            // and gets overwritten on disk when a later .exe in the
            // archive supersedes the earlier pick (e.g. Reborn1950
            // ships [Patcher.exe (skipped), Reborn.exe, Game.exe]:
            // Reborn writes first, Game.exe overwrites). The path
            // string is unchanged across those writes, so a guard
            // here would skip the SwiftUI re-render. The card would
            // keep showing the first icon decoded into the
            // ImageCache until a reload-time view rebuild swaps it
            // for the latest disk content. That produces a visible
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
