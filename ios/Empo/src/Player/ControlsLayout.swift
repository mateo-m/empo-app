import Foundation
import Observation
import SwiftUI

struct ButtonModel: Identifiable, Equatable, Codable {
    let id: UUID
    var label: String
    var scancode: Int32
    var relativeCenter: CGPoint  // fraction of superview size
    var size: CGFloat
    /// Per-button opacity in [0, 1]. Applied to the whole button view,
    /// so it tones down both the glass background and the label.
    /// Defaults to 1.0 (fully opaque) for new and legacy-decoded
    /// buttons so existing saved layouts remain unchanged.
    var opacity: Double

    enum CodingKeys: String, CodingKey {
        case label, scancode, size, opacity
        case rx, ry
    }

    init(label: String, scancode: Int32, relativeCenter: CGPoint, size: CGFloat, opacity: Double = 1.0) {
        self.id = UUID()
        self.label = label
        self.scancode = scancode
        self.relativeCenter = relativeCenter
        self.size = size
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.scancode = try c.decodeIfPresent(Int32.self, forKey: .scancode) ?? 0
        let rx = try c.decodeIfPresent(CGFloat.self, forKey: .rx) ?? 0.5
        let ry = try c.decodeIfPresent(CGFloat.self, forKey: .ry) ?? 0.5
        self.relativeCenter = CGPoint(x: rx, y: ry)
        self.size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? 56
        self.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(scancode, forKey: .scancode)
        try c.encode(relativeCenter.x, forKey: .rx)
        try c.encode(relativeCenter.y, forKey: .ry)
        try c.encode(size, forKey: .size)
        try c.encode(opacity, forKey: .opacity)
    }
}

private struct PersistedLayout: Codable {
    struct DPad: Codable {
        var rx: CGFloat
        var ry: CGFloat
        var size: CGFloat
        /// Per-D-pad opacity in [0, 1]. Decoded with a 1.0 fallback
        /// so older persisted layouts (missing the key) continue
        /// loading without surprising transparency.
        var opacity: Double?
    }
    var dpad: DPad
    var buttons: [ButtonModel]
}

@MainActor
@Observable
class ControlsLayout {
    static let shared = ControlsLayout()

    private static let savedLayoutKey = "touchControlsLayout"

    var dpadRelativeCenter: CGPoint = CGPoint(x: 0.13, y: 0.72)
    var dpadSize: CGFloat = 140
    var dpadOpacity: Double = 1.0
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
        dpadOpacity = 1.0
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
            dpadOpacity = 1.0
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
                withAnimation(Motion.gentle) {
                    buttons.append(button)
                }
            }
        }
    }


    func save() {
        let layout = PersistedLayout(
            dpad: .init(rx: dpadRelativeCenter.x, ry: dpadRelativeCenter.y, size: dpadSize, opacity: dpadOpacity),
            buttons: buttons
        )
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: Self.savedLayoutKey)
        }
    }

    @discardableResult
    func loadLayout() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.savedLayoutKey),
              let layout = try? JSONDecoder().decode(PersistedLayout.self, from: data) else {
            return false
        }

        dpadRelativeCenter = CGPoint(x: layout.dpad.rx, y: layout.dpad.ry)
        dpadSize = layout.dpad.size
        dpadOpacity = layout.dpad.opacity ?? 1.0
        buttons = layout.buttons

        return true
    }


    func addButton(label: String, scancode: Int32) {
        var displayLabel = label
        if let range = label.range(of: " (") {
            displayLabel = String(label[..<range.lowerBound])
        }
        let button = ButtonModel(label: displayLabel, scancode: scancode,
                                 relativeCenter: CGPoint(x: 0.5, y: 0.5), size: 56)
        withAnimation(Motion.gentle) {
            buttons.append(button)
        }
    }

    func removeButton(id: UUID) {
        buttons.removeAll { $0.id == id }
    }

    func updateButton(id: UUID, label: String? = nil, scancode: Int32? = nil, size: CGFloat? = nil, relativeCenter: CGPoint? = nil, opacity: Double? = nil) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        if let label { buttons[index].label = label }
        if let scancode { buttons[index].scancode = scancode }
        if let size { buttons[index].size = size }
        if let relativeCenter { buttons[index].relativeCenter = relativeCenter }
        if let opacity { buttons[index].opacity = opacity }
    }
}
