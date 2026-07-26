import Foundation
import UIKit

/// mkxp's `CoreSession`: a thin adapter over the EXISTING
/// process-global engine machinery (`EngineSessionCoordinator.shared`
/// / `GameSession`). It moves no engine logic - every method makes
/// the exact call `AppState` made directly before the session seam
/// existed, in the same order, on the same (main) thread, so mkxp
/// games behave bit-identically. The adapter exists so a SECOND
/// session type can be instantiated by `CoreKind`
/// (`docs/plans/emulator-cores.md`).
@MainActor
final class MkxpSession: CoreSession {
    private let coordinator = EngineSessionCoordinator.shared
    private let launch: GameSession.LaunchInput

    let capabilities: CoreCapabilities

    /// SDL owns a process-global `UIWindow`; `GameViewEmbedder`
    /// reparents its game view into `AppWindow` while the game
    /// plays. The session has no `UIView` of its own to hand over.
    var surface: CoreSurface { .sdlHostedWindow }

    init(launch: GameSession.LaunchInput) {
        self.launch = launch
        self.capabilities = MkxpCore().capabilities(
            for: launch.game, metadata: launch.metadata)
    }

    /// Exactly the sequence `AppState.selectGame` ran before the
    /// seam: configure the engine bridge synchronously at the call
    /// site, then hand the game path to the RGSS thread once any
    /// previous session's termination handshake completes.
    func start() {
        coordinator.configureEngine(launch)
        Task { @MainActor in
            await coordinator.launchGamePath(launch.game.path)
        }
    }

    func requestPause() {
        coordinator.requestPause()
    }

    func requestResume() {
        coordinator.requestResume()
    }

    /// Unreachable today: mkxp declares `quitToLibrary: false`, so
    /// `AppState.returnToLibrary` keeps driving mkxp termination
    /// through `beginReturnToLibrary` + the hang watchdog directly
    /// (docs/multi-session.md). This entry completes the contract
    /// for generic callers with the same coordinator call that path
    /// makes (play-time flush, crash-marker removal, terminate
    /// request); the watchdog remains `AppState`-side UX.
    func requestTerminate() {
        _ = coordinator.beginReturnToLibrary(selectedContainer: launch.container)
    }

    func injectInput(_ event: CoreInputEvent) {
        switch event {
        case .scancode(let scancode, let pressed):
            coordinator.injectKey(scancode: scancode, pressed: pressed)
        }
    }
}

extension MkxpCore: SessionProviding {
    /// `delegate` is unused on purpose: mkxp's events keep flowing
    /// through the pre-existing `EngineSessionCoordinatorDelegate`
    /// wiring (`AppState` conforms), because re-routing them
    /// through `CoreSessionDelegate` would be a behavior change
    /// while mkxp must stay bit-identical. A future full extraction
    /// can flip event routing here without touching the contract.
    func makeSession(
        launch: GameSession.LaunchInput,
        delegate: CoreSessionDelegate
    ) -> (any CoreSession)? {
        MkxpSession(launch: launch)
    }
}
