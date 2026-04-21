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

    /// Stable identifier of the game these controls are currently
    /// bound to. `switchGame(id:)` updates this; mutators save to the
    /// corresponding per-game key. `nil` means no game is active -
    /// mutations are kept in memory but not persisted, which prevents
    /// drive-by saves during library-screen interactions.
    private(set) var currentGameID: String?

    var dpadRelativeCenter: CGPoint = CGPoint(x: 0.13, y: 0.72)
    var dpadSize: CGFloat = 140
    var dpadOpacity: Double = 1.0
    var buttons: [ButtonModel] = []

    private init() {
        resetToDefaults()
    }

    /// Bind the layout instance to a specific game's stored layout.
    /// Called from `AppState.selectGame(_:)` when a game starts, and
    /// again with `nil` from `returnToLibrary()` when the user exits.
    ///
    /// The transition flow:
    ///   1. Save the *previous* game's current in-memory state to
    ///      its per-game key (so any pending edits aren't lost).
    ///   2. Update `currentGameID`.
    ///   3. Load the new game's saved layout, or fall back to
    ///      factory defaults if this is the first time the game is
    ///      being played.
    func switchGame(id newGameID: String?) {
        if currentGameID != nil {
            save()
        }
        currentGameID = newGameID
        if newGameID != nil, loadLayout() {
            return
        }
        resetToDefaults()
    }

    private var savedLayoutKey: String? {
        guard let id = currentGameID else { return nil }
        return DefaultsKey.controlsLayout(gameID: id)
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


    /// Persist the current layout under the active game's per-game
    /// key. No-op when `currentGameID` is nil - without a bound game
    /// there's nowhere to save. Safe to call from drag-end / exit-
    /// edit-mode paths; the guard prevents library-screen UI mutations
    /// from accidentally writing to a previous game's slot.
    func save() {
        guard let key = savedLayoutKey else { return }
        let layout = PersistedLayout(
            dpad: .init(rx: dpadRelativeCenter.x, ry: dpadRelativeCenter.y, size: dpadSize, opacity: dpadOpacity),
            buttons: buttons
        )
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Load the active game's persisted layout into this instance.
    /// Returns false if there's no saved layout for the current game
    /// (so the caller can fall back to factory defaults). Also returns
    /// false when no game is bound.
    @discardableResult
    func loadLayout() -> Bool {
        guard let key = savedLayoutKey,
              let data = UserDefaults.standard.data(forKey: key),
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
