import Foundation

/// One per engine runtime. Stateless; `CoreRegistry` owns one
/// instance per `CoreKind` (`docs/plans/emulator-cores.md`).
///
/// This half of the contract stays minimal on purpose: identity
/// plus a per-game capability declaration. The session half lives
/// in `CoreSession.swift` (`CoreSession` + `CoreSessionDelegate`,
/// generalizing today's `EngineSessionCoordinator` /
/// `EngineSessionCoordinatorDelegate` and
/// `GameSession.LaunchInput`); session construction is a separate
/// factory protocol (`SessionProviding`) rather than a requirement
/// here, so phase 1 conformances - including adapters that live in
/// core repos, like rmweb-core's `RmWebCore` - keep compiling
/// untouched.
protocol GameCore: Sendable {
    var kind: CoreKind { get }

    /// Static capabilities, refined per game at resolve time (e.g.
    /// MV vs MZ, RGSS version mask, network policy).
    func capabilities(for entry: GameEntry, metadata: GameMetadata) -> CoreCapabilities
}
