import Foundation

/// Where a resolved screen region came from. Absence is a normal,
/// silent outcome: it never logs and never surfaces a notice.
public enum ScreenProvenance: Equatable, Sendable {
    case profile(String)
    case engineAuto
}

/// The screen chain, per orientation. It is NOT the controls chain:
/// a pin is TERMINAL for the screen. A named pin without a screen
/// entry means engine-auto — never the default profile's region —
/// so a profile can always express "stock placement" while a
/// default region exists. `$game` also means engine-auto: games
/// cannot dictate placement, and `$game` says "present this game
/// the stock way". Only `$default` and follow-the-chain read the
/// default profile.
public enum ScreenResolution {
    public struct Outcome: Equatable, Sendable {
        public var placement: ScreenPlacement?
        public var provenance: ScreenProvenance

        public init(placement: ScreenPlacement?, provenance: ScreenProvenance) {
            self.placement = placement
            self.provenance = provenance
        }
    }

    public struct Result: Equatable, Sendable {
        public var portrait: Outcome
        public var landscape: Outcome

        public init(portrait: Outcome, landscape: Outcome) {
            self.portrait = portrait
            self.landscape = landscape
        }
    }

    public static func resolve(
        pin: LayoutPin,
        defaultProfileName: String?,
        readScreen: (String) -> ScreenRegionFile.ReadResult?
    ) -> Result {
        let auto = Outcome(placement: nil, provenance: .engineAuto)

        let sourceName: String?
        switch pin {
        case .profile(let name):
            sourceName = name
        case .gameLayout:
            sourceName = nil
        case .defaultProfile, .followChain:
            sourceName = defaultProfileName
        }

        guard let sourceName, let read = readScreen(sourceName) else {
            return Result(portrait: auto, landscape: auto)
        }

        func outcome(_ placement: ScreenPlacement?) -> Outcome {
            guard let placement else { return auto }
            return Outcome(placement: placement, provenance: .profile(sourceName))
        }
        return Result(
            portrait: outcome(read.portrait), landscape: outcome(read.landscape))
    }
}
