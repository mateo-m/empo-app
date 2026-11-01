// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// What Empo tells Empo Player about the game to run. Empo passes it
/// as JSON after `--launch`.
struct PlayerLaunch: Codable {
    struct Setting: Codable {
        let key: String
        let value: String
    }

    let title: String
    let corePath: String
    let gamePath: String
    let userDataDirectory: String?
    let fontsDirectory: String
    let verticalAlignment: GameCoreVerticalAlignment
    let fixedAspectRatio: Bool
    let settings: [Setting]
    let debugLogPath: String?
    let caBundlePath: String?
    let fastForwardMultiplier: Int?
    let iconPath: String?

    static let argument = "--launch"
    /// Empo Player opens the core at the path after it, then ends with
    /// status 0, or 70 when the core does not open.
    static let checkCoreArgument = "--check-core"

    func arguments() throws -> [String] {
        // JSONEncoder always writes UTF-8, so the decode cannot fail.
        // swiftlint:disable:next optional_data_string_conversion
        [Self.argument, String(decoding: try JSONEncoder().encode(self), as: UTF8.self)]
    }

    /// Nil when the process has no `--launch` argument.
    static func fromProcessArguments() throws -> PlayerLaunch? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        return try JSONDecoder().decode(PlayerLaunch.self, from: Data(arguments[index + 1].utf8))
    }
}

extension GameCoreVerticalAlignment: @retroactive Codable {}

/// A line that Empo Player writes to its standard output for Empo.
enum PlayerMessage: String {
    case paused
    case resumed
}
