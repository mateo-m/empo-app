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
        let pin = store.loadPin(forGameFolder: gameFolder).pin

        var pinnedName: String?
        var pinnedValid: Bool?
        if case .profile(let name) = pin {
            pinnedName = name
            let read = store.readProfile(name)
            pinnedValid = read?.invalid == false && read?.touch != nil
        }

        let gameOccupied: Bool
        if let gameRoot {
            let outcome = ControlsManifestLoader.load(gameRoot: gameRoot, metrics: metrics)
            gameOccupied = outcome?.result.manifest?.touch != nil
        } else {
            gameOccupied = false
        }

        var defaultValid: Bool?
        if let defaultProfileName {
            let read = store.readProfile(defaultProfileName)
            defaultValid = read?.invalid == false && read?.touch != nil
        }

        let outcome = LayoutChainResolver.resolve(
            pin: pin,
            levels: LayoutChainResolver.Levels(
                pinnedProfileValid: pinnedValid,
                gameLayoutOccupied: gameOccupied,
                defaultProfileValid: defaultValid
            )
        )

        let provenance: LayoutProvenance
        switch outcome.level {
        case .pinnedProfile:
            provenance = .pinnedProfile(pinnedName ?? "")
        case .gameLayout:
            provenance = .gameLayout
        case .defaultProfile:
            provenance = .defaultProfile(defaultProfileName ?? "")
        case .builtin:
            provenance = .builtin
        }
        return Result(provenance: provenance, fellThrough: outcome.fellThrough)
    }
}
