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
/// session start and again at session end, and takes the difference.
/// The cost is one stat pass per session on each side, off the main
/// actor, and no descriptor at all. It changes no engine code:
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

    private struct Session {
        let container: GameContainer
        let startedAt: Date
        var reading: Task<[String: FileStamp], Never>
    }

    // MARK: - The session

    /// Takes the first reading. `EngineSessionCoordinator` calls
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
            startedAt: Date(),
            reading: Task.detached(priority: .utility) {
                Self.readTree(at: gameURL)
            })
    }

    /// Takes the second reading and applies the rules of 3.6. The
    /// call is safe with no session open, because the return path
    /// and the engine-termination path both reach it.
    func endSession() {
        guard let session else { return }
        self.session = nil

        let container = session.container
        let startedAt = session.startedAt
        let reading = session.reading
        let alreadyJoined = joinedPathsByGame[container.id] ?? []

        Task { [weak self] in
            let before = await reading.value
            let result = await Task.detached(priority: .utility) {
                Self.watchResult(
                    container: container, before: before, startedAt: startedAt,
                    alreadyJoined: alreadyJoined)
            }.value
            guard let result else { return }
            self?.apply(result, forGame: container.id)
        }
    }

    /// The second reading and the rules, off the main actor. The
    /// pass stats the whole game tree, so it must not run where the
    /// UI runs.
    nonisolated private static func watchResult(
        container: GameContainer,
        before: [String: FileStamp],
        startedAt: Date,
        alreadyJoined: Set<String>
    ) -> RuntimeWatchResult? {
        let after = readTree(at: container.gameURL)
        let intent = GameBackupIntent.load(from: container.empoStateURL)
        guard intent.mode == .slim else { return nil }

        let written = RuntimeWatch.writtenPaths(before: before, after: after, since: startedAt)
        let files = written.compactMap { path -> BackupSetResolver.WalkedFile? in
            guard let stamp = after[path] else { return nil }
            return BackupSetResolver.WalkedFile(
                path: path, size: stamp.size, modifiedAt: stamp.modifiedAt)
        }

        let inSet =
            alreadyJoined
            .union(BackupSetResolver.classifierMatches(containerURL: container.url))
            .union(intent.manualMarks)
        return RuntimeWatch.result(
            written: files,
            mode: .slim,
            declined: Set(intent.declinedSuggestions),
            alreadyInSet: inSet)
    }

    private func apply(_ result: RuntimeWatchResult, forGame containerId: String) {
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
    func joinedPaths(forGame containerId: String) -> [String] {
        (joinedPathsByGame[containerId] ?? []).sorted()
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
