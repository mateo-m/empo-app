import Foundation
import GameProbe

/// The game cores Empo can carry. A release build embeds one of them or
/// both, so every place that names a core goes through this type.
///
/// The raw value is the framework name inside the app bundle.
enum GameCoreKind: String, CaseIterable {
    case rpgMaker = "MkxpCore"
    case psdk = "PsdkCore"

    /// Each core answers the launcher interface under its own prefix,
    /// so the forwarders need the one this core uses.
    var symbolPrefix: String {
        switch self {
        case .rpgMaker: return "mkxp_"
        case .psdk: return "psdk_"
        }
    }

    /// The name a player reads on the Game cores screen, and in the
    /// message that refuses a game this build cannot run.
    var displayName: String {
        switch self {
        case .rpgMaker: return "RPG Maker core"
        case .psdk: return "Pokemon SDK core"
        }
    }

    /// What import throws when this build carries no such core. The
    /// library alert says the same, with the name of the game.
    var notInThisBuildMessage: String {
        "This build of Empo has no \(displayName), so it can't run this game."
    }

    static func forGame(at gameDirectory: URL) -> GameCoreKind {
        PsdkGame.isGameRoot(gameDirectory) ? .psdk : .rpgMaker
    }
}
