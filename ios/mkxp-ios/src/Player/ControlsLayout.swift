import Foundation
import Observation
import SwiftUI

/// Model for a single action button's persistent state.
struct ButtonModel: Identifiable, Equatable {
    let id: UUID
    var label: String
    var scancode: Int32
    var relativeCenter: CGPoint  // fraction of superview size
    var size: CGFloat

    init(label: String, scancode: Int32, relativeCenter: CGPoint, size: CGFloat) {
        self.id = UUID()
        self.label = label
        self.scancode = scancode
        self.relativeCenter = relativeCenter
        self.size = size
    }

    init(from dict: [String: Any]) {
        self.id = UUID()
        self.label = dict["label"] as? String ?? ""
        self.scancode = Int32(dict["scancode"] as? Int ?? 0)
        let rx = dict["rx"] as? CGFloat ?? 0.5
        let ry = dict["ry"] as? CGFloat ?? 0.5
        self.relativeCenter = CGPoint(x: rx, y: ry)
        self.size = dict["size"] as? CGFloat ?? 56
    }

    func toDict() -> [String: Any] {
        return [
            "label": label,
            "scancode": Int(scancode),
            "rx": relativeCenter.x,
            "ry": relativeCenter.y,
            "size": size,
        ]
    }
}

/// Manages the layout of touch controls (d-pad + action buttons) with persistence.
@MainActor
@Observable
class ControlsLayout {
    static let shared = ControlsLayout()

    private static let savedLayoutKey = "touchControlsLayout"

    var dpadRelativeCenter: CGPoint = CGPoint(x: 0.13, y: 0.72)
    var dpadSize: CGFloat = 140
    var buttons: [ButtonModel] = []

    private init() {
        if !loadLayout() {
            resetToDefaults()
        }
    }


    static let defaultDPadCenter = CGPoint(x: 0.13, y: 0.72)
    static let defaultDPadSize: CGFloat = 140
    static let defaultButtons: [ButtonModel] = [
        ButtonModel(label: "A",     scancode: Int32(MKXP_SCANCODE_RETURN), relativeCenter: CGPoint(x: 0.85, y: 0.78), size: 60),
        ButtonModel(label: "B",     scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.72, y: 0.70), size: 56),
        ButtonModel(label: "Shift", scancode: Int32(MKXP_SCANCODE_LSHIFT), relativeCenter: CGPoint(x: 0.62, y: 0.82), size: 50),
        ButtonModel(label: "Esc",   scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.92, y: 0.62), size: 44),
    ]

    func resetToDefaults() {
        dpadRelativeCenter = Self.defaultDPadCenter
        dpadSize = Self.defaultDPadSize
        buttons = Self.defaultButtons
    }

    func resetWithStagger() {
        let defaults = Self.defaultButtons
        var matchedIDs = Set<UUID>()
        var matchedDefaults = Set<Int>()

        // Match current buttons to defaults by label + scancode
        var moves: [(id: UUID, center: CGPoint, size: CGFloat)] = []
        for (di, def) in defaults.enumerated() {
            guard let current = buttons.first(where: {
                $0.label == def.label && $0.scancode == def.scancode && !matchedIDs.contains($0.id)
            }) else { continue }

            matchedIDs.insert(current.id)
            matchedDefaults.insert(di)

            let posChanged = abs(current.relativeCenter.x - def.relativeCenter.x) > 0.001
                          || abs(current.relativeCenter.y - def.relativeCenter.y) > 0.001
            let sizeChanged = abs(current.size - def.size) > 0.5
            if posChanged || sizeChanged {
                moves.append((current.id, def.relativeCenter, def.size))
            }
        }

        // Animate: remove extras, move displaced, reset D-pad
        // Controls already at default are untouched (no-op = no animation).
        withAnimation(Motion.standard) {
            buttons.removeAll { !matchedIDs.contains($0.id) }
            for move in moves {
                updateButton(id: move.id, size: move.size, relativeCenter: move.center)
            }
            dpadRelativeCenter = Self.defaultDPadCenter
            dpadSize = Self.defaultDPadSize
        }

        // Stagger-add missing defaults (scale/blur/opacity transition)
        let missing = defaults.enumerated()
            .filter { !matchedDefaults.contains($0.offset) }
            .sorted {
                if $0.element.relativeCenter.y != $1.element.relativeCenter.y {
                    return $0.element.relativeCenter.y < $1.element.relativeCenter.y
                }
                return $0.element.relativeCenter.x < $1.element.relativeCenter.x
            }

        for (i, (_, button)) in missing.enumerated() {
            let delay = 0.15 + Double(i) * 0.06
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.spring(duration: 0.35, bounce: 0)) {
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            buttons.append(button)
        }
                }
            }
        }
    }


    func save() {
        let dpadDict: [String: Any] = [
            "rx": dpadRelativeCenter.x,
            "ry": dpadRelativeCenter.y,
            "size": dpadSize,
        ]
        let btnDicts = buttons.map { $0.toDict() }
        let layout: [String: Any] = [
            "dpad": dpadDict,
            "buttons": btnDicts,
        ]
        UserDefaults.standard.set(layout, forKey: Self.savedLayoutKey)
    }

    @discardableResult
    func loadLayout() -> Bool {
        guard let layout = UserDefaults.standard.dictionary(forKey: Self.savedLayoutKey) else {
            return false
        }

        if let dd = layout["dpad"] as? [String: Any] {
            let rx = dd["rx"] as? CGFloat ?? Self.defaultDPadCenter.x
            let ry = dd["ry"] as? CGFloat ?? Self.defaultDPadCenter.y
            dpadRelativeCenter = CGPoint(x: rx, y: ry)
            dpadSize = dd["size"] as? CGFloat ?? Self.defaultDPadSize
        }

        if let btnDicts = layout["buttons"] as? [[String: Any]] {
            buttons = btnDicts.map { ButtonModel(from: $0) }
        }

        return true
    }


    func addButton(label: String, scancode: Int32) {
        var displayLabel = label
        if let range = label.range(of: " (") {
            displayLabel = String(label[..<range.lowerBound])
        }
        let button = ButtonModel(label: displayLabel, scancode: scancode,
                                 relativeCenter: CGPoint(x: 0.5, y: 0.5), size: 56)
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            buttons.append(button)
        }
    }

    func removeButton(id: UUID) {
        buttons.removeAll { $0.id == id }
    }

    func updateButton(id: UUID, label: String? = nil, scancode: Int32? = nil, size: CGFloat? = nil, relativeCenter: CGPoint? = nil) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        if let label { buttons[index].label = label }
        if let scancode { buttons[index].scancode = scancode }
        if let size { buttons[index].size = size }
        if let relativeCenter { buttons[index].relativeCenter = relativeCenter }
    }
}
