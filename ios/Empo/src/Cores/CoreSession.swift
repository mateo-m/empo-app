import UIKit

/// Where a live session renders (`docs/plans/emulator-cores.md`).
/// Consumed by `AppWindow.applyOverlayPresentationMode`, which picks
/// the embedder for the surface when the player appears.
enum CoreSurface {
    /// The core renders into SDL's process-global `UIWindow`, and
    /// `GameViewEmbedder` owns the reparenting dance into
    /// `AppWindow`. mkxp's window is created by the engine and
    /// lives for the process lifetime, so the session cannot hand
    /// over a plain `UIView` - "the SDL embedder owns it" is the
    /// honest contract.
    case sdlHostedWindow
    /// The core owns an ordinary `UIView` (e.g. a `WKWebView`)
    /// that the app hosts directly via `CoreViewEmbedder`.
    case view(UIView)
}

/// One input event delivered to a live session. SDL scancodes are
/// the controls layer's native currency (`KeyCatalog`, controls
/// manifests, controller maps), so they stay the wire format; a
/// core whose `inputInjection` capability is not `.sdlScancode`
/// translates at its own boundary (rmWeb maps scancodes to the
/// runtime's logical key names inside its adapter).
enum CoreInputEvent {
    case scancode(Int32, pressed: Bool)
}

/// Engine → app events for one live session. Mirrors the event half
/// of `EngineSessionCoordinatorDelegate` method-for-method (same
/// names minus the `coordinator` prefix, same semantics), so the
/// mkxp mapping is mechanical. `AppState` conforms and funnels each
/// method into the same handler its coordinator twin uses.
///
/// mkxp's events deliberately keep flowing through the pre-existing
/// `EngineSessionCoordinatorDelegate` wiring - re-routing them
/// would be a behavior change the cores plan forbids while mkxp
/// must stay bit-identical. Today only rmWeb sessions deliver
/// through this protocol (dormant until the MV/MZ import gate
/// opens).
@MainActor
protocol CoreSessionDelegate: AnyObject {
    /// Twin of `coordinatorFrameRendered` ("first-frame-ish": the
    /// session became ready / drew after a resume).
    func sessionFrameRendered()
    /// Twin of `coordinatorEngineTerminatedUnexpectedly(cleanExit:)`:
    /// the session ended without the app requesting it.
    func sessionTerminated(cleanExit: Bool)
    /// Twin of `coordinatorGameRectDidChange`.
    func sessionGameRectDidChange(_ rect: CGRect)
    /// Twin of `coordinatorDidReportEngineError`.
    func sessionDidReportError(_ message: String)
    /// Twin of `coordinatorDidReportEngineInfo`.
    func sessionDidReportInfo(_ message: String)
    /// Twin of `coordinatorEngineDidPause(snapshot:)`.
    func sessionDidPause(snapshot: UIImage?)
}

/// One live game run (`docs/plans/emulator-cores.md`). mkxp's
/// implementation (`MkxpSession`) is a thin adapter over today's
/// process-global `EngineSessionCoordinator`; rmWeb's
/// (`RmWebSession`) owns a disposable `RmWebHostController`.
/// `AppState.selectGame` instantiates one per launch by the game's
/// `resolvedCoreKind`.
@MainActor
protocol CoreSession: AnyObject {
    /// The owning core's declaration for this game, resolved at
    /// session creation. Drives the capability branches in
    /// `AppState` (`quitToLibrary`, `sequentialSessions`) and
    /// `SessionInputRouter` (`inputInjection`).
    var capabilities: CoreCapabilities { get }

    var surface: CoreSurface { get }

    /// Begin the run. Non-async by design: mkxp's implementation
    /// must configure the engine bridge synchronously at the call
    /// site (exactly where `selectGame` did before the seam) and
    /// only await the previous session's termination handshake
    /// inside its own task, preserving the pre-cores ordering.
    func start()

    func requestPause()
    func requestResume()

    /// Ask the session to end. Only meaningful for cores declaring
    /// `quitToLibrary`; mkxp termination keeps flowing through
    /// `AppState.returnToLibrary`'s coordinator choreography.
    func requestTerminate()

    func injectInput(_ event: CoreInputEvent)
}

/// Session factory. A separate protocol instead of a `makeSession`
/// requirement on `GameCore`, so phase 1's conformances (including
/// `RmWebCore` in the rmweb-core repo's Empo adapter, which this
/// repo cannot edit atomically) stay untouched; `MkxpCore` and
/// `RmWebCore` adopt it next to their session types.
@MainActor
protocol SessionProviding {
    /// nil when the game can no longer be resolved for this core
    /// (e.g. its files changed since import); the caller surfaces
    /// the standard invalid-game error.
    func makeSession(
        launch: GameSession.LaunchInput,
        delegate: CoreSessionDelegate
    ) -> (any CoreSession)?
}

/// Last-mile key routing for the on-screen controls and physical
/// controllers. Branches on the running core's `inputInjection`
/// capability at the injection call site:
/// - `.sdlScancode` keeps today's exact
///   `EngineSessionCoordinator.injectKey` path (bit-identical for
///   mkxp: same call, same order, same thread).
/// - `.domKeyEvent` routes through the session's input entry, which
///   translates the scancode to the core's own currency.
/// Call sites keep speaking scancodes either way.
@MainActor
enum SessionInputRouter {
    static func injectKey(scancode: Int32, pressed: Bool) {
        if let session = AppState.shared.activeSession,
            session.capabilities.inputInjection == .domKeyEvent
        {
            session.injectInput(.scancode(scancode, pressed: pressed))
            return
        }
        // `.sdlScancode` - and, defensively, no live session
        // object - both take the pre-cores direct path.
        EngineSessionCoordinator.shared.injectKey(scancode: scancode, pressed: pressed)
    }
}
