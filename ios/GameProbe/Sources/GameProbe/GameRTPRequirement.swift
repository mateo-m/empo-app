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

    /// The RTPs that Empo can import, without duplicates.
    public var knownPackages: [RTPPackage] {
        var seen = Set<RTPPackage>()
        return packages.compactMap(RTPPackage.init(gameINIValue:)).filter { seen.insert($0).inserted }
    }

    /// The names of the RTPs that the game can't read, for alert copy,
    /// without duplicates. Empo can't add an RTP that it doesn't know,
    /// so a name such as a fan-made RTP is always missing.
    public func missingNames(isInstalled: (RTPPackage) -> Bool) -> [String] {
        var seen = Set<String>()
        return packages.compactMap { value in
            guard let package = RTPPackage(gameINIValue: value) else { return value }
            return isInstalled(package) ? nil : package.engineName
        }
        .filter { seen.insert($0.lowercased()).inserted }
    }
}
