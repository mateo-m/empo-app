// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation

public struct ControlTouchSet<TouchID: Hashable & Sendable>: Sendable {
    public private(set) var live: [TouchID] = []

    public init() {}

    public var isEngaged: Bool {
        !live.isEmpty
    }

    public func isTracking(_ id: TouchID) -> Bool {
        live.contains(id)
    }

    public mutating func begin(_ id: TouchID) -> Bool {
        guard !live.contains(id) else { return false }
        live.append(id)
        return live.count == 1
    }

    public enum EndOutcome: Equatable, Sendable {
        case notTracked
        case stillEngaged
        case idle
    }

    /// UIKit can send both touchesEnded and touchesCancelled for one
    /// touch. The second end returns `notTracked`, so the control does
    /// not release twice.
    public mutating func end(_ id: TouchID) -> EndOutcome {
        guard let index = live.firstIndex(of: id) else { return .notTracked }
        live.remove(at: index)
        return live.isEmpty ? .idle : .stillEngaged
    }

    /// When the app disables or removes the control during a touch,
    /// UIKit can skip the touch ends. The caller closes each returned
    /// touch as a real lift does.
    public mutating func reset() -> [TouchID] {
        let abandoned = live
        live.removeAll()
        return abandoned
    }
}

public enum ControlHitShape {
    public static func circleContains(width: Double, height: Double, x: Double, y: Double) -> Bool {
        let radius = min(width, height) / 2
        let dx = x - width / 2
        let dy = y - height / 2
        return dx * dx + dy * dy <= radius * radius
    }
}
