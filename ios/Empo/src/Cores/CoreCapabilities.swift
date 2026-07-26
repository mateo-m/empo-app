import Foundation

/// What a core *can do or enforce*, declared per game at resolve
/// time. Declarative and data-first: consumed by UI gating and the
/// import validator instead of hardcodes
/// (`docs/plans/emulator-cores.md`).
///
/// Design rule: a capability is what the core can do or enforce; a
/// setting is what the user chooses per game. "Has network
/// features" is not a capability - `networkEnabled` stays a
/// per-game setting; the capability is whether the core can honor
/// it.
///
/// Design rule two: no speculative capabilities. Every field must
/// have a consumer in the UI or import pipeline and differ between
/// the two real cores (or plausibly differ for the next one). Grow
/// the struct when a third core needs it, not before.
struct CoreCapabilities: Equatable, Sendable {
    /// How touch controls deliver input to the running game.
    /// Consumer: the controls-manifest layer's last-mile key
    /// injection (`TouchControls.mm` / `KeyCatalog`).
    enum InputInjectionKind: Equatable, Sendable {
        /// Synthetic SDL key events (`mkxp_injectKeyEvent`).
        case sdlScancode
        /// DOM `KeyboardEvent`s dispatched into a web view.
        case domKeyEvent
    }

    /// Whether the core can enforce the per-game network toggle.
    /// Consumer: the "Network access" row in `GameSettingsView`.
    enum NetworkControl: Equatable, Sendable {
        /// The core honors `GameSettings.networkEnabled`.
        case enforceable
        /// The core cannot restrict the game's network use.
        case unavailable
    }

    /// One diagnostics-overlay datum the core can report.
    /// Consumer: `DebugOverlayView` renders only the fields the
    /// core declares.
    enum DiagnosticField: Hashable, Sendable {
        case fps
        case rendererName  // e.g. ANGLE/Metal
        case engineVersion  // e.g. RGSS version, MV/MZ corescript
        case rubyVersion
        case compatibilityMode
    }

    /// Can a game end and return to the library without killing the
    /// process? Consumers: the in-game Quit row
    /// (`PlayerMoreSheet.quitEnabled`) and the long-press Quit
    /// context action (`GameContextMenu`).
    let quitToLibrary: Bool

    /// Can another game start in the same process afterwards?
    /// Consumers: the library "A game is paused" alert
    /// (`GameLibraryView`) and the clean-exit "force-close Empo"
    /// alert copy (`RootView` / `GameLoadingView`) - every site
    /// `docs/multi-session.md` lists.
    let sequentialSessions: Bool

    /// Pause with frozen-frame snapshot (hero-zoom transitions,
    /// background pause). Consumers: `PauseManager` and the pause
    /// row in `PlayerMoreSheet`.
    let pauseSnapshot: Bool

    /// Consumers: the fast-forward toggle in `PlayerMoreSheet` and
    /// the speed slider in `GameSettingsView`.
    let fastForward: Bool

    /// Consumer: the Cheats row in `PlayerMoreSheet`.
    let cheats: Bool

    /// How touch controls deliver input: SDL scancodes vs. DOM key
    /// events.
    let inputInjection: InputInjectionKind

    /// Whether the core supports an in-game text-entry keyboard.
    /// Consumers: the player toolbar's keyboard toggle and the
    /// "In-game keyboard" row in `GameSettingsView`.
    let inGameKeyboardText: Bool

    /// Whether the core can map touches to mouse input. Consumer:
    /// the "Touch acts as mouse" row in `GameSettingsView`.
    let touchMouse: Bool

    /// Whether the core can enforce the per-game network toggle.
    let networkControl: NetworkControl

    /// Whether the core surfaces in-game modal dialogs (Ruby
    /// `msgbox` / `p`) to the host. Consumer: `RootView`'s
    /// info/error alerts.
    let modalDialogBridge: Bool

    /// Diagnostics-overlay fields the core can report (fps,
    /// renderer name, engine version, …). Consumer:
    /// `DebugOverlayView`.
    let diagnostics: Set<DiagnosticField>
}
