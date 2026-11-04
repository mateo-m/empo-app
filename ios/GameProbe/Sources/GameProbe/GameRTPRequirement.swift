// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// RTP (Run-Time Package) dependency declared in a game's `Game.ini`.
///
/// RPG Maker games can reference shared Enterbrain assets (graphics,
/// audio, fonts) without bundling them. The `[Game]` section names the
/// installed RTP package(s) via `rtp`, `RTP`, `RTP1`, `RTP2`, or `RTP3`.
public struct GameRTPRequirement: Sendable, Equatable {
    public let packages: [String]

    public init(packages: [String]) {
        self.packages = packages
    }

    /// Returns a requirement when `Game.ini` names at least one
    /// non-empty RTP package under `[Game]`.
    public static func detect(at gameDir: URL) -> GameRTPRequirement? {
        // `GameINI` matches keys case-insensitively, so one lookup per
        // logical slot is enough (`rtp` covers `RTP` in shipped inis).
        let keys = ["rtp", "rtp1", "rtp2", "rtp3"]
        var packages: [String] = []
        for key in keys {
            guard let value = GameINI.parseINIValue(at: gameDir, section: "game", key: key),
                !value.isEmpty
            else { continue }
            packages.append(value)
        }
        guard !packages.isEmpty else { return nil }
        return GameRTPRequirement(packages: packages)
    }

    /// Comma-separated RTP identifiers as written in `Game.ini`.
    public var summary: String {
        packages.joined(separator: ", ")
    }

    /// Human-readable engine names for alert copy.
    public var friendlyNames: [String] {
        packages.map(Self.friendlyPackageName)
    }

    private static func friendlyPackageName(_ package: String) -> String {
        switch package.trimmingCharacters(in: .whitespaces).lowercased() {
        case "rpgvxace": "RPG Maker VX Ace"
        case "rpgvx": "RPG Maker VX"
        case "standard": "RPG Maker XP"
        default: package
        }
    }
}
