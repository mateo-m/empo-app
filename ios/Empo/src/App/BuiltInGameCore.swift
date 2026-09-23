import Foundation

/// One game core inside this build of the app. A build can ship one core
/// or both, so a kind whose framework is absent is absent here too.
struct BuiltInGameCore: Identifiable {
    let kind: GameCoreKind
    let games: String
    let version: String

    var id: String { kind.rawValue }
    var displayName: String { kind.displayName }

    static let all: [BuiltInGameCore] = GameCoreKind.allCases.compactMap(read)

    static func isInThisBuild(_ kind: GameCoreKind) -> Bool {
        all.contains { $0.kind == kind }
    }

    /// EngineSessionCoordinator.openCore dlopens this path, so a core is
    /// part of the build only when the binary is there. An embed phase
    /// that skips a core leaves no framework folder at all.
    static func binaryURL(for kind: GameCoreKind) -> URL? {
        guard
            let url = Bundle.main.privateFrameworksURL?
                .appendingPathComponent("\(kind.rawValue).framework")
                .appendingPathComponent(kind.rawValue),
            FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    /// Which RGSS versions the RPG Maker core runs, as the bitmask
    /// tools/mkxp-core/build-framework-ios.sh writes. Zero when this
    /// build has no RPG Maker core.
    ///
    /// This reads the framework's Info.plist, not
    /// `gamecore_getSupportedRGSSVersionMask`, so it answers before any
    /// core opens.
    static var rgssVersionMask: Int {
        bundle(for: .rpgMaker)?
            .object(forInfoDictionaryKey: "EmpoCoreRGSSVersionMask") as? Int ?? 0
    }

    private static func bundle(for kind: GameCoreKind) -> Bundle? {
        guard let binary = binaryURL(for: kind) else { return nil }
        return Bundle(url: binary.deletingLastPathComponent())
    }

    /// The two build-framework-ios.sh scripts write EmpoCoreVersion.
    private static func read(_ kind: GameCoreKind) -> BuiltInGameCore? {
        guard let bundle = bundle(for: kind) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "EmpoCoreVersion") as? String
        return BuiltInGameCore(
            kind: kind, games: games(kind), version: version ?? "unknown")
    }

    /// GameImportValidator refuses a game the mask does not cover, so
    /// this line follows the mask. check-mkxp-framework.sh allows 3,
    /// which is RGSS1 and RGSS2, and 7, which adds RGSS3.
    private static func games(_ kind: GameCoreKind) -> String {
        switch kind {
        case .psdk:
            return "Runs Pokemon SDK games"
        case .rpgMaker:
            return rgssVersionMask == 7
                ? "Runs RPG Maker XP, VX and VX Ace games"
                : "Runs RPG Maker XP and VX games"
        }
    }
}
