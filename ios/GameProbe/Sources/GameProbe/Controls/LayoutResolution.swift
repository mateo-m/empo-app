import Foundation

/// Off-player chain resolution: what a game's layout resolves to
/// right now, from files alone. The pickers use it for the
/// "Automatic" row and the bound layout uses the same logic through
/// the app. Returns the provenance plus whether a pinned target was
/// missing and the resolution fell through.
public enum LayoutResolution {
    public struct Result: Equatable, Sendable {
        public var provenance: LayoutProvenance
        public var fellThrough: Bool

        public init(provenance: LayoutProvenance, fellThrough: Bool) {
            self.provenance = provenance
            self.fellThrough = fellThrough
        }
    }

    public static func resolve(
        gameFolder: URL,
        gameRoot: URL?,
        store: LayoutProfileStore,
        defaultProfileName: String?,
        metrics: TouchZoneMetrics = .reference
    ) -> Result {
        resolve(
            pin: store.loadPin(forGameFolder: gameFolder).pin,
            gameRoot: gameRoot,
            store: store,
            defaultProfileName: defaultProfileName,
            metrics: metrics)
    }

    /// The pin-aware entry: callers that already hold the pin (the
    /// bound layout, the picker's "Automatic" row via
    /// `.followChain`) gather the SAME levels the file-based entry
    /// does, so the chain logic exists once.
    public static func resolve(
        pin: LayoutPin,
        gameRoot: URL?,
        store: LayoutProfileStore,
        defaultProfileName: String?,
        metrics: TouchZoneMetrics = .reference
    ) -> Result {
        let outcome = LayoutChainResolver.resolve(
            pin: pin,
            levels: levels(
                pin: pin, gameRoot: gameRoot, store: store,
                defaultProfileName: defaultProfileName, metrics: metrics)
        )
        return Result(provenance: outcome.provenance, fellThrough: outcome.fellThrough)
    }

    /// Per-level occupancy from files. Shared by both entries.
    public static func levels(
        pin: LayoutPin,
        gameRoot: URL?,
        store: LayoutProfileStore,
        defaultProfileName: String?,
        metrics: TouchZoneMetrics = .reference
    ) -> LayoutChainResolver.Levels {
        var pinnedProfile: (name: String, valid: Bool)?
        if case .profile(let name) = pin {
            pinnedProfile = (name, store.validTouch(name) != nil)
        }

        let gameOccupied: Bool
        if let gameRoot {
            let outcome = ControlsManifestLoader.load(gameRoot: gameRoot, metrics: metrics)
            gameOccupied = outcome?.result.manifest?.touch != nil
        } else {
            gameOccupied = false
        }

        var defaultProfile: (name: String, valid: Bool)?
        if let defaultProfileName {
            defaultProfile = (defaultProfileName, store.validTouch(defaultProfileName) != nil)
        }

        return LayoutChainResolver.Levels(
            pinnedProfile: pinnedProfile,
            gameLayoutOccupied: gameOccupied,
            defaultProfile: defaultProfile
        )
    }
}
