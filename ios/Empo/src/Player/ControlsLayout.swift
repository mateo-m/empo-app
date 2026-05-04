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


/// Active orientation for the controls overlay. Each game stores
/// independent layouts per orientation; buttons sized via fraction
/// of viewport are unworkable across orientation flips because the
/// aspect ratio inverts (portrait 0.09 vertical gap = 79pt, but the
/// same fraction in landscape collapses to 37pt and overlaps the
/// 56pt button), so we keep two layouts instead.
enum ControlsOrientation: String, Codable {
    case portrait
    case landscape

    static func from(geoSize size: CGSize) -> ControlsOrientation {
        size.height > size.width ? .portrait : .landscape
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
    struct Oriented: Codable {
        var dpad: DPad
        var buttons: [ButtonModel]
    }
    var portrait: Oriented
    var landscape: Oriented
}

/// V1 (pre-orientation) on-disk shape. Decoder tries V2 first; if
/// that fails, we fall through to V1 and migrate by treating it as
/// the portrait layout and seeding landscape from defaults.
private struct PersistedLayoutV1: Codable {
    var dpad: PersistedLayout.DPad
    var buttons: [ButtonModel]
}


@MainActor
@Observable
class ControlsLayout {
    static let shared = ControlsLayout()

    /// Stable identifier of the game these controls are currently
    /// bound to. `switchGame(id:)` updates this; mutators save to the
    /// corresponding per-game key. `nil` means no game is active;
    /// mutations are kept in memory but not persisted.
    private(set) var currentGameID: String?

    /// Current device orientation as far as the layout is concerned.
    /// PlayerView updates this via `setOrientation(_:)` when geometry
    /// flips; orientation changes save the current "active" values
    /// into the matching snapshot before loading the other.
    private(set) var currentOrientation: ControlsOrientation = .portrait

    // MARK: - Active layout (current orientation)
    //
    // Views read/write these directly. They always represent the
    // layout for `currentOrientation`. When orientation changes,
    // `setOrientation(_:)` snapshots them into the matching slot
    // below and loads the other slot back into these.

    var dpadRelativeCenter: CGPoint = ControlsLayout.defaultDPadCenterPortrait
    var dpadSize: CGFloat = ControlsLayout.defaultDPadSize
    var dpadOpacity: Double = 1.0
    var buttons: [ButtonModel] = []

    // MARK: - Inactive snapshots

    /// Snapshot of the orientation NOT currently active. The active
    /// orientation's values live in the public `dpad*`/`buttons`
    /// properties above; the other lives here. Swapped in/out by
    /// `setOrientation(_:)`.
    private var inactiveDpadRelativeCenter: CGPoint = ControlsLayout.defaultDPadCenterLandscape
    private var inactiveDpadSize: CGFloat = ControlsLayout.defaultDPadSize
    private var inactiveDpadOpacity: Double = 1.0
    private var inactiveButtons: [ButtonModel] = ControlsLayout.defaultButtonsLandscape

    private init() {
        applyDefaultsForCurrentOrientation()
    }

    /// Bind the layout instance to a specific game's stored layout.
    /// Called from `AppState.selectGame(_:)` when a game starts, and
    /// again with `nil` from `returnToLibrary()` when the user exits.
    func switchGame(id newGameID: String?) {
        if currentGameID != nil {
            save()
        }
        currentGameID = newGameID
        if newGameID != nil, loadLayout() {
            return
        }
        applyDefaultsForCurrentOrientation()
    }

    /// Switch the active orientation. Snapshot the current "active"
    /// values into the matching slot, then load the other slot's
    /// values back into the active properties.
    ///
    /// No-op if `new == currentOrientation`. Called from PlayerView's
    /// `.onChange(of: isPortrait)` so the layout follows device
    /// rotation in real time.
    func setOrientation(_ new: ControlsOrientation) {
        guard new != currentOrientation else { return }

        // Snapshot the orientation we're leaving.
        let leavingDpadCenter = dpadRelativeCenter
        let leavingDpadSize = dpadSize
        let leavingDpadOpacity = dpadOpacity
        let leavingButtons = buttons

        // Promote the inactive slot into the active properties.
        dpadRelativeCenter = inactiveDpadRelativeCenter
        dpadSize = inactiveDpadSize
        dpadOpacity = inactiveDpadOpacity
        buttons = inactiveButtons

        // Demote the previous active values into the inactive slot.
        inactiveDpadRelativeCenter = leavingDpadCenter
        inactiveDpadSize = leavingDpadSize
        inactiveDpadOpacity = leavingDpadOpacity
        inactiveButtons = leavingButtons

        currentOrientation = new
    }

    private var savedLayoutKey: String? {
        guard let id = currentGameID else { return nil }
        return DefaultsKey.controlsLayout(gameID: id)
    }


    /// Seed an initial layout for a game ID that isn't currently
    /// active. Used by the JGP import path so the game starts with
    /// the layout bundled in the archive rather than our defaults.
    /// Overwrites any existing persisted layout, so only call during
    /// first import. Marked `nonisolated` because it only writes to
    /// UserDefaults and touches no instance state, which lets the
    /// import pipeline (running on a background Task) seed layouts
    /// without hopping to the main actor.
    ///
    /// The bundled JGP layout is treated as the portrait layout; the
    /// landscape slot gets the engine default. Users can edit each
    /// independently after import.
    nonisolated static func writeInitialPerGameLayout(
        gameID: String,
        dpadCenter: CGPoint,
        dpadSize: CGFloat,
        dpadOpacity: Double = 1.0,
        buttons: [ButtonModel]
    ) {
        let portrait = PersistedLayout.Oriented(
            dpad: .init(rx: dpadCenter.x, ry: dpadCenter.y,
                        size: dpadSize, opacity: dpadOpacity),
            buttons: buttons
        )
        let landscape = PersistedLayout.Oriented(
            dpad: .init(
                rx: defaultDPadCenterLandscape.x,
                ry: defaultDPadCenterLandscape.y,
                size: defaultDPadSize,
                opacity: 1.0
            ),
            buttons: defaultButtonsLandscape
        )
        let layout = PersistedLayout(portrait: portrait, landscape: landscape)
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data,
            forKey: DefaultsKey.controlsLayout(gameID: gameID))
    }


    // MARK: - Defaults
    //
    // Default constants are `nonisolated` so the `nonisolated`
    // `writeInitialPerGameLayout` (called from background import
    // tasks) and the JGP import pipeline can read them without
    // hopping to the main actor. They're plain Swift `let`s of
    // value types; safe to read from any thread.

    nonisolated static let defaultDPadCenterPortrait = CGPoint(x: 0.13, y: 0.72)
    nonisolated static let defaultDPadCenterLandscape = CGPoint(x: 0.10, y: 0.65)
    nonisolated static let defaultDPadSize: CGFloat = 140

    /// Legacy alias. Some imports / migration paths still reference
    /// `defaultDPadCenter` (singular); keep it pointing at the
    /// portrait default so callers without orientation context get
    /// the more common case.
    nonisolated static let defaultDPadCenter = defaultDPadCenterPortrait

    /// 2x2 button grid in the bottom-right of a portrait viewport.
    nonisolated static let defaultButtonsPortrait: [ButtonModel] = [
        ButtonModel(label: "Enter",  scancode: Int32(MKXP_SCANCODE_RETURN), relativeCenter: CGPoint(x: 0.70, y: 0.67), size: 56),
        ButtonModel(label: "Escape", scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.88, y: 0.67), size: 56),
        ButtonModel(label: "Z",      scancode: Int32(MKXP_SCANCODE_Z),      relativeCenter: CGPoint(x: 0.70, y: 0.76), size: 56),
        ButtonModel(label: "B",      scancode: Int32(MKXP_SCANCODE_B),      relativeCenter: CGPoint(x: 0.88, y: 0.76), size: 56),
    ]

    /// 2x2 button grid in the bottom-right of a landscape viewport.
    /// Shorter screen height + wider screen width means the grid
    /// can sit higher and more spread out without overlapping the
    /// game viewport's center.
    nonisolated static let defaultButtonsLandscape: [ButtonModel] = [
        ButtonModel(label: "Enter",  scancode: Int32(MKXP_SCANCODE_RETURN), relativeCenter: CGPoint(x: 0.80, y: 0.59), size: 56),
        ButtonModel(label: "Escape", scancode: Int32(MKXP_SCANCODE_ESCAPE), relativeCenter: CGPoint(x: 0.88, y: 0.59), size: 56),
        ButtonModel(label: "Z",      scancode: Int32(MKXP_SCANCODE_Z),      relativeCenter: CGPoint(x: 0.80, y: 0.75), size: 56),
        ButtonModel(label: "B",      scancode: Int32(MKXP_SCANCODE_B),      relativeCenter: CGPoint(x: 0.88, y: 0.75), size: 56),
    ]

    /// Legacy alias for callers that grab "the" defaults without
    /// orientation. Returns the portrait set.
    nonisolated static var defaultButtons: [ButtonModel] { defaultButtonsPortrait }


    // MARK: - Reset

    func resetToDefaults() {
        applyDefaultsForCurrentOrientation()
        // Also reset the inactive orientation so "reset" wipes both
        // (matches user intent: reset = factory state for this game).
        switch currentOrientation {
        case .portrait:
            inactiveDpadRelativeCenter = Self.defaultDPadCenterLandscape
            inactiveButtons = Self.defaultButtonsLandscape
        case .landscape:
            inactiveDpadRelativeCenter = Self.defaultDPadCenterPortrait
            inactiveButtons = Self.defaultButtonsPortrait
        }
        inactiveDpadSize = Self.defaultDPadSize
        inactiveDpadOpacity = 1.0
    }

    private func applyDefaultsForCurrentOrientation() {
        switch currentOrientation {
        case .portrait:
            dpadRelativeCenter = Self.defaultDPadCenterPortrait
            buttons = Self.defaultButtonsPortrait
            inactiveDpadRelativeCenter = Self.defaultDPadCenterLandscape
            inactiveButtons = Self.defaultButtonsLandscape
        case .landscape:
            dpadRelativeCenter = Self.defaultDPadCenterLandscape
            buttons = Self.defaultButtonsLandscape
            inactiveDpadRelativeCenter = Self.defaultDPadCenterPortrait
            inactiveButtons = Self.defaultButtonsPortrait
        }
        dpadSize = Self.defaultDPadSize
        dpadOpacity = 1.0
        inactiveDpadSize = Self.defaultDPadSize
        inactiveDpadOpacity = 1.0
    }

    func resetWithStagger() {
        let defaults = currentOrientation == .portrait
            ? Self.defaultButtonsPortrait
            : Self.defaultButtonsLandscape
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
        let defaultDpadCenter = currentOrientation == .portrait
            ? Self.defaultDPadCenterPortrait
            : Self.defaultDPadCenterLandscape
        withAnimation(Motion.standard) {
            buttons.removeAll { !matchedIDs.contains($0.id) }
            for move in moves {
                updateButton(id: move.id, size: move.size, relativeCenter: move.center)
            }
            dpadRelativeCenter = defaultDpadCenter
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
            let delay = Motion.controlsAppearDelay + Double(i) * Motion.staggerMedium
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(Motion.gentle) {
                    buttons.append(button)
                }
            }
        }
    }


    // MARK: - Persistence

    /// Persist the current layout under the active game's per-game
    /// key. No-op when `currentGameID` is nil.
    ///
    /// Saves BOTH orientations: the active one snapshotted from the
    /// public `dpad*`/`buttons` properties, the inactive one
    /// pulled from the private snapshot fields.
    func save() {
        guard let key = savedLayoutKey else { return }
        let active = PersistedLayout.Oriented(
            dpad: .init(
                rx: dpadRelativeCenter.x, ry: dpadRelativeCenter.y,
                size: dpadSize, opacity: dpadOpacity
            ),
            buttons: buttons
        )
        let inactive = PersistedLayout.Oriented(
            dpad: .init(
                rx: inactiveDpadRelativeCenter.x,
                ry: inactiveDpadRelativeCenter.y,
                size: inactiveDpadSize,
                opacity: inactiveDpadOpacity
            ),
            buttons: inactiveButtons
        )
        let layout: PersistedLayout
        switch currentOrientation {
        case .portrait:
            layout = PersistedLayout(portrait: active, landscape: inactive)
        case .landscape:
            layout = PersistedLayout(portrait: inactive, landscape: active)
        }
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Load the active game's persisted layout into this instance.
    /// Returns false if there's no saved layout for the current game
    /// (so the caller can fall back to factory defaults).
    ///
    /// Tries V2 (per-orientation) first. Falls through to V1 (legacy
    /// single-layout) and migrates: the V1 layout becomes the
    /// portrait layout, landscape gets the engine default. Re-saves
    /// in V2 shape on first successful migration so subsequent loads
    /// take the V2 path.
    @discardableResult
    func loadLayout() -> Bool {
        guard let key = savedLayoutKey,
              let data = UserDefaults.standard.data(forKey: key) else {
            return false
        }

        if let v2 = try? JSONDecoder().decode(PersistedLayout.self, from: data) {
            applyV2(v2)
            return true
        }

        if let v1 = try? JSONDecoder().decode(PersistedLayoutV1.self, from: data) {
            // Migrate V1 → V2: the saved layout becomes portrait;
            // landscape gets defaults.
            let portrait = PersistedLayout.Oriented(dpad: v1.dpad, buttons: v1.buttons)
            let landscape = PersistedLayout.Oriented(
                dpad: .init(
                    rx: Self.defaultDPadCenterLandscape.x,
                    ry: Self.defaultDPadCenterLandscape.y,
                    size: Self.defaultDPadSize,
                    opacity: 1.0
                ),
                buttons: Self.defaultButtonsLandscape
            )
            applyV2(PersistedLayout(portrait: portrait, landscape: landscape))
            // Re-save so next load takes the V2 path.
            save()
            return true
        }

        return false
    }

    private func applyV2(_ layout: PersistedLayout) {
        let active: PersistedLayout.Oriented
        let inactive: PersistedLayout.Oriented
        switch currentOrientation {
        case .portrait:
            active = layout.portrait
            inactive = layout.landscape
        case .landscape:
            active = layout.landscape
            inactive = layout.portrait
        }
        dpadRelativeCenter = CGPoint(x: active.dpad.rx, y: active.dpad.ry)
        dpadSize = active.dpad.size
        dpadOpacity = active.dpad.opacity ?? 1.0
        buttons = active.buttons
        inactiveDpadRelativeCenter = CGPoint(x: inactive.dpad.rx, y: inactive.dpad.ry)
        inactiveDpadSize = inactive.dpad.size
        inactiveDpadOpacity = inactive.dpad.opacity ?? 1.0
        inactiveButtons = inactive.buttons
    }


    // MARK: - Mutators

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
