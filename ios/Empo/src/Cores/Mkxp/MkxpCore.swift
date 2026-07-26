import Foundation

/// The mkxp-z core: RGSS 1/2/3 (RPG Maker XP / VX / VX Ace) via
/// the mkxp-z-apple-mobile engine. The engine itself lives behind
/// the `mkxp_*` C bridge; this type only declares the core's
/// identity and capabilities for the launcher's generic contract.
struct MkxpCore: GameCore {
    let kind: CoreKind = .mkxp

    /// The full RGSS family, not just the engine name: "mkxp-z"
    /// alone would tell an importing user nothing about which RPG
    /// Maker generations run here. Trailing "and mkxp-z" keeps the
    /// pre-cores rejection sentence byte-identical (mkxp-z-native
    /// games are a real JGP runtime type of their own).
    let supportedGamesDescription = "RPG Maker XP, VX, VX Ace, and mkxp-z"

    /// mkxp-z's capability declaration.
    ///
    /// `quitToLibrary` and `sequentialSessions` are false because
    /// the engine's SDL/GL/OpenAL/Ruby state is process-lifetime:
    /// CRuby's `ruby_init()` is one-shot per process, and cleaning
    /// a live VM's leaked classes/monkey-patches between two
    /// arbitrary games proved unreliable, so every mid-game quit
    /// path is neutralized and the user force-closes the app
    /// instead. See `docs/multi-session.md` for the full history
    /// and the list of disabled quit paths.
    static let declaredCapabilities = CoreCapabilities(
        quitToLibrary: false,
        sequentialSessions: false,
        pauseSnapshot: true,
        fastForward: true,
        cheats: true,
        inputInjection: .sdlScancode,
        inGameKeyboardText: true,
        touchMouse: true,
        networkControl: .enforceable,
        modalDialogBridge: true,
        diagnostics: [.fps, .rendererName, .engineVersion, .rubyVersion, .compatibilityMode]
    )

    func capabilities(for entry: GameEntry, metadata: GameMetadata) -> CoreCapabilities {
        // No per-game refinement yet: every RGSS game gets the same
        // declaration. The entry/metadata parameters exist so a
        // core can refine per game (e.g. MV vs MZ for rmWeb).
        Self.declaredCapabilities
    }
}
