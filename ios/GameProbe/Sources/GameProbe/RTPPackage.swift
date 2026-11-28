// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

/// The RPG Maker RTPs that Empo can import. The raw value is the name
/// that `Game.ini` gives, and the name of the folder of the copy.
public enum RTPPackage: String, CaseIterable, Sendable, Identifiable {
    case xp = "Standard"
    case vx = "RPGVX"
    case vxAce = "RPGVXAce"

    public var id: String { rawValue }

    public init?(gameINIValue: String) {
        let value = gameINIValue.trimmingCharacters(in: .whitespaces)
        guard
            let package = Self.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(value) == .orderedSame
            })
        else { return nil }
        self = package
    }

    public var engineName: String {
        switch self {
        case .xp: "RPG Maker XP"
        case .vx: "RPG Maker VX"
        case .vxAce: "RPG Maker VX Ace"
        }
    }

    /// Each RTP has a Graphics folder that the others do not have.
    /// VX Ace also has `Faces`, so `Titles1` is checked first.
    static func detect(graphicsFolders: Set<String>) -> RTPPackage? {
        let names = Set(graphicsFolders.map { $0.lowercased() })
        if names.contains("titles1") { return .vxAce }
        if names.contains("windowskins") { return .xp }
        if names.contains("faces") { return .vx }
        return nil
    }
}
