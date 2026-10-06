import Foundation
import GameProbe

/// The runtime watch of SPEC 3.6, wired to the play session.
///
/// The spec fixes the behavior and not the mechanism. iOS has no
/// recursive directory watch. `DispatchSource` on a directory file
/// descriptor reports that directory alone and not its subtree, so a
/// watch at `Game/` would miss `Game/save/`, and a watch per
/// candidate directory needs one descriptor per directory and still
/// misses a directory the game makes while it runs.
///
/// So this reads the size and the modified time of `Game/` at
/// session start and again at each later reading, and takes the
/// difference. The cost is one stat pass for each reading, off the
/// main actor, and no descriptor at all. It changes no engine code:
/// `mkxp-z-apple-mobile` stays launcher-agnostic.
///
/// The watch runs in slim mode only. Full mode holds the whole tree
/// already, per 3.6, so there is nothing for a join to add.
@MainActor
final class GameSaveWatch {

    static let shared = GameSaveWatch()

    /// The joins of this app run, keyed by container folder name.
    ///
    /// A join has no store of its own. The manifest carries the
    /// label per entry, per 3.6, so ticket 006 reads these paths
    /// into the run that closes the session's stream, and the next
    /// launch reads the joins of every earlier session back from the
    /// last manifest. That keeps 6.3 true: the cache is never truth.
    private var joinedPathsByGame: [String: Set<String>] = [:]

    /// The paths over the 50 MB limit that wait for an answer, per
    /// 3.6. Tickets 017 and 018 show the ask.
    private var pendingAsksByGame: [String: [String]] = [:]

    private var session: Session?

    /// The reading in flight. `joinedPaths` waits for it, so a pass
    /// that starts right after the session end sees the last joins.
    private var reading: Task<Void, Never>?

    private struct Session {
        let container: GameContainer
        /// The time the baseline pass started. `RuntimeWatch` counts
        /// a file changed at or after it as written, which covers a
        /// write that lands while the pass walks the tree.
        var readingStartedAt: Date
        var baseline: Task<[String: FileStamp], Never>
    }

    /// One pass over the tree: what it found, and what the rules
    /// made of it.
    private struct Pass: Sendable {
        let after: [String: FileStamp]
        let result: RuntimeWatchResult?
    }

    // MARK: - The session

    /// Takes the baseline reading. `EngineSessionCoordinator` calls
    /// this as it configures the engine, so the reading runs beside
    /// the launch and not in front of it.
    func beginSession(container: GameContainer) {
        endSession()
        guard GameBackupIntent.load(from: container.empoStateURL).mode == .slim else {
            return
        }
        let gameURL = container.gameURL
        session = Session(
            container: container,
            readingStartedAt: Date(),
            baseline: Task.detached(priority: .utility) {
                Self.readTree(at: gameURL)
            })
    }

    /// Reads the tree again, applies the rules of 3.6, and keeps the
    /// session open with this reading as the new baseline.
    ///
    /// Empo has no quit: a session ends when the game exits itself,
    /// when it crashes, or when the user closes the app from the app
    /// switcher, per `docs/multi-session.md`. The last one gives no
    /// callback, so the watch reads at every point where it can lose
    /// the chance. `AppState.flushSessionPlayTimeForBackground`
    /// keeps play time the same way.
    ///
    /// Repeat calls are safe. A path that already joined is in the
    /// set, so a second reading of the same write changes nothing.
    func takeReading() {
        guard let open = session else { return }
        let container = open.container
        let baseline = open.baseline
        let since = open.readingStartedAt
        let alreadyJoined = joinedPathsByGame[container.id] ?? []
        let passStartedAt = Date()

        let pass = Task.detached(priority: .utility) { () -> Pass in
            let before = await baseline.value
            return Self.pass(
                container: container, before: before, since: since,
                alreadyJoined: alreadyJoined)
        }
        session?.baseline = Task.detached(priority: .utility) { await pass.value.after }
        session?.readingStartedAt = passStartedAt

        let earlier = reading
        reading = Task { [weak self] in
            await earlier?.value
            guard let result = await pass.value.result else { return }
            self?.apply(result, forGame: container.id)
        }
    }

    /// Takes a last reading and closes the session. The call is safe
    /// with no session open, because the engine-termination path
    /// reaches it after a reading may have already run.
    ///
    /// The last reading runs on after this returns. `joinedPaths`
    /// waits for it, so the next backup pass holds its joins.
    func endSession() {
        guard session != nil else { return }
        takeReading()
        session = nil
    }

    /// One pass and the rules, off the main actor. The pass stats
    /// the whole game tree, so it must not run where the UI runs.
    nonisolated private static func pass(
        container: GameContainer,
        before: [String: FileStamp],
        since: Date,
        alreadyJoined: Set<String>
    ) -> Pass {
        let after = readTree(at: container.gameURL)
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        guard intent.mode == .slim else { return Pass(after: after, result: nil) }

        let written = RuntimeWatch.writtenPaths(before: before, after: after, since: since)
        let files = written.compactMap { path -> BackupSetResolver.WalkedFile? in
            guard let stamp = after[path] else { return nil }
            return BackupSetResolver.WalkedFile(
                path: path, size: stamp.size, modifiedAt: stamp.modifiedAt)
        }

        let inSet =
            alreadyJoined
            .union(BackupSetResolver.classifierMatches(containerURL: container.url))
            .union(intent.manualMarks)
        let result = RuntimeWatch.result(
            written: files,
            mode: .slim,
            declined: Set(intent.declinedSuggestions),
            alreadyInSet: inSet)
        return Pass(after: after, result: result)
    }

    private func apply(_ result: RuntimeWatchResult, forGame containerId: String) {
        // The Backups screen and the Backup sheet do not exist yet,
        // so this line is the only place a join shows. Tickets 016
        // and 018 read the same numbers into the UI.
        if AppSettings.shared.debugLogs, !result.isEmpty {
            NSLog(
                "[GameSaveWatch] %@: %ld joined, %ld to ask, %ld suggested: %@",
                containerId,
                result.joined.count,
                result.asks.count,
                result.suggestions.count,
                (result.joined + result.asks).joined(separator: ", "))
        }
        if !result.joined.isEmpty {
            joinedPathsByGame[containerId, default: []].formUnion(result.joined)
        }
        if !result.asks.isEmpty {
            var asks = pendingAsksByGame[containerId] ?? []
            for path in result.asks where !asks.contains(path) {
                asks.append(path)
            }
            pendingAsksByGame[containerId] = asks.sorted()
        }
    }

    // MARK: - What the resolver and the UI read

    /// The paths this app run joined for one game, for the
    /// `runtimeWatchPaths` of `GameBackupSetRequest`.
    func joinedPaths(forGame containerId: String) async -> [String] {
        await reading?.value
        return (joinedPathsByGame[containerId] ?? []).sorted()
    }

    /// The paths over the 50 MB limit that wait for an answer.
    func pendingAsks(forGame containerId: String) -> [String] {
        pendingAsksByGame[containerId] ?? []
    }

    /// The user said yes to an oversized file. It joins like any
    /// watched write.
    func acceptAsk(path: String, forGame containerId: String) {
        pendingAsksByGame[containerId]?.removeAll { $0 == path }
        joinedPathsByGame[containerId, default: []].insert(path)
    }

    /// The user said no. The path becomes a declined suggestion in
    /// `backup.json`, so it never asks again, per 3.6.
    func declineAsk(path: String, container: GameContainer) {
        pendingAsksByGame[container.id]?.removeAll { $0 == path }
        let stateURL = container.empoStateURL
        let intent = RuntimeWatch.declining(
            path, in: GameBackupIntent.load(from: stateURL))
        try? intent.save(to: stateURL)
    }

    // MARK: - The reading

    /// The size and the modified time of every file under `Game/`,
    /// keyed by the path relative to the container.
    ///
    /// The paths carry the `Game/` prefix, because every other path
    /// in the backup set is container-relative too.
    nonisolated private static func readTree(at gameURL: URL) -> [String: FileStamp] {
        var stamps: [String: FileStamp] = [:]
        for file in BackupSetResolver.files(under: gameURL) {
            let path = "\(BackupSetRules.gameDirectoryName)/\(file.path)"
            guard !BackupSetRules.isAlwaysOut(containerRelativePath: path) else { continue }
            stamps[path] = FileStamp(size: file.size, modifiedAt: file.modifiedAt)
        }
        return stamps
    }
}
