import Foundation

/// One per engine runtime. Stateless; `CoreRegistry` owns one
/// instance per `CoreKind` (`docs/plans/emulator-cores.md`).
///
/// Phase 1 of the cores plan keeps this contract minimal on
/// purpose: identity plus a per-game capability declaration. The
/// session half of the contract (`CoreSession` +
/// `CoreSessionDelegate`, generalizing today's
/// `EngineSessionCoordinator` / `EngineSessionCoordinatorDelegate`
/// and `GameSession.LaunchInput`) is a later mechanical extraction
/// - `EngineSessionCoordinator` is deeply wired into `AppState`
/// (delegate conformance, pause/play-time/crash-marker plumbing),
/// and moving it behind a protocol is exactly the kind of
/// wide-blast-radius change the plan defers until the capability
/// layer has proven out. `EngineSessionCoordinatorDelegate` is
/// already engine-neutral, so it is the seam that extraction will
/// formalize.
protocol GameCore: Sendable {
    var kind: CoreKind { get }

    /// Static capabilities, refined per game at resolve time (e.g.
    /// MV vs MZ, RGSS version mask, network policy).
    func capabilities(for entry: GameEntry, metadata: GameMetadata) -> CoreCapabilities
}
