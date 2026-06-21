import Foundation

/// Per-game Ruby interpreter version detection.
///
/// Delegates to `GameScriptProfile` for the actual sniff. This type
/// remains as the stable name for call sites and documentation.
enum RubyVersionDetection {

    typealias Schema = GameScriptProfile.Schema

    static var currentSchema: Schema { GameScriptProfile.currentSchema }

    static func detect(gameDirectory: URL) -> Int {
        GameScriptProfile.analyze(gameDirectory: gameDirectory).rubyVersion
    }
}
