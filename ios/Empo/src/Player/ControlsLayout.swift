import Foundation
import GameProbe
import Observation
import SwiftUI
import UIKit

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

    init(
        label: String, scancode: Int32, relativeCenter: CGPoint, size: CGFloat, opacity: Double = 1.0
    ) {
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

/// A touch button bound to an Empo action instead of a game key.
/// No label: rendering uses the action's fixed icon and the registry
/// display name. Codable so `PersistedLayout` stays decodable, though
/// legacy UserDefaults blobs never contain these.
struct ActionButtonModel: Identifiable, Equatable, Codable {
    let id: UUID
    var action: String
    var relativeCenter: CGPoint  // fraction of superview size
    var size: CGFloat
    var opacity: Double

    enum CodingKeys: String, CodingKey {
        case action, size, opacity
        case rx, ry
    }

    init(action: String, relativeCenter: CGPoint, size: CGFloat, opacity: Double = 1.0) {
        self.id = UUID()
        self.action = action
        self.relativeCenter = relativeCenter
        self.size = size
        self.opacity = opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        let rx = try c.decodeIfPresent(CGFloat.self, forKey: .rx) ?? 0.5
        let ry = try c.decodeIfPresent(CGFloat.self, forKey: .ry) ?? 0.5
        self.relativeCenter = CGPoint(x: rx, y: ry)
        self.size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? 56
        self.opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(relativeCenter.x, forKey: .rx)
        try c.encode(relativeCenter.y, forKey: .ry)
        try c.encode(size, forKey: .size)
        try c.encode(opacity, forKey: .opacity)
    }
}

/// Active orientation for the controls overlay. Each game stores
/// an independent layout per orientation. Buttons sized as a
/// fraction of the viewport do not survive an orientation flip
/// because the aspect ratio inverts. A portrait 0.09 vertical gap
/// is 79pt, but the
/// same fraction in landscape collapses to 37pt and overlaps the
/// 56pt button. So we keep two layouts instead.
enum ControlsOrientation: String, Codable {
    case portrait
    case landscape

    static func from(geoSize size: CGSize) -> ControlsOrientation {
        size.height > size.width ? .portrait : .landscape
    }
}

private struct PersistedLayout: Codable {
    struct DPad: Codable, Equatable {
        var rx: CGFloat
        var ry: CGFloat
        var size: CGFloat
        /// Per-D-pad opacity in [0, 1].
        var opacity: Double?
        /// Never optional in memory. The custom decoder maps a
        /// missing key (legacy blobs) to `.dpad`, so a nil-vs-.dpad
        /// mismatch can never make `hasTouchCustomization` true for
        /// an untouched game — the type enforces what a comment
        /// used to ask for.
        var style: MovementStyle

        init(
            rx: CGFloat, ry: CGFloat, size: CGFloat, opacity: Double? = nil,
            style: MovementStyle = .dpad
        ) {
            self.rx = rx
            self.ry = ry
            self.size = size
            self.opacity = opacity
            self.style = style
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rx = try container.decode(CGFloat.self, forKey: .rx)
            ry = try container.decode(CGFloat.self, forKey: .ry)
            size = try container.decode(CGFloat.self, forKey: .size)
            opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
            style =
                try container.decodeIfPresent(MovementStyle.self, forKey: .style) ?? .dpad
        }
    }
    struct Oriented: Codable, Equatable {
        var dpad: DPad
        var buttons: [ButtonModel]
        /// Optional so legacy UserDefaults blobs (no such key) still
        /// decode. nil and [] mean the same thing.
        var actionButtons: [ActionButtonModel]?

        init(dpad: DPad, buttons: [ButtonModel], actionButtons: [ActionButtonModel]? = nil) {
            self.dpad = dpad
            self.buttons = buttons
            self.actionButtons = actionButtons
        }
    }
    var portrait: Oriented
    var landscape: Oriented
}

/// V1 (pre-orientation) on-disk shape. The decoder tries V2 first.
/// If that fails, we fall through to V1 and migrate: we treat it as
/// the portrait layout, and we seed landscape from defaults.
private struct PersistedLayoutV1: Codable {
    var dpad: PersistedLayout.DPad
    var buttons: [ButtonModel]
}

@MainActor
@Observable
class ControlsLayout {
    static let shared = ControlsLayout()

    /// Stable identifier of the game these controls are currently
    /// bound to. `switchGame(id:container:)` updates this. Mutators
    /// save to the matching per-game file. `nil` means no game is
    /// active, so mutations stay in memory and never reach disk.
    private(set) var currentGameID: String?

    /// Container for the active game (EmpoState paths). `switchGame`
    /// sets it together with `currentGameID`.
    private(set) var currentContainer: GameContainer?

    /// Accepted developer manifest for the active game, if any.
    private(set) var activeManifest: ControlsManifest?

    /// Loader source for `activeManifest` (kirin / joiplay / empo / root).
    private(set) var activeManifestSource: ControlsManifestLoader.ManifestLocation?

    /// True when the active touch resolution derived one orientation
    /// from the other (metrics-dependent, see `refreshForGameGeometryChange`).
    private(set) var resolutionInvolvesDerivation = false

    /// Error findings from a rejected shipped `controls.json`, for edit-mode surfacing.
    private(set) var manifestRejectionErrorCount = 0

    /// Error findings from a rejected pinned profile file.
    private(set) var profileRejectionErrorCount = 0

    /// Which chain level currently drives the layout. Banners,
    /// pickers, and the save target all key off this.
    private(set) var provenance: LayoutProvenance = .builtin

    /// True when a pinned target was missing or invalid and the
    /// resolution fell through to a lower level.
    private(set) var pinFellThrough = false

    /// A migrated-then-changed per-game controls file waits for the
    /// user's import decision.
    private(set) var importOfferPending = false

    /// One-time notice: the game ships its own layout while a default
    /// profile is set, so the default did not apply.
    private(set) var gameLayoutNoticePending = false

    /// Display title of the bound game, for auto-created profile names.
    private(set) var currentGameTitle: String?

    /// What the chain yields when no named pin applies, snapshotted at
    /// resolution time. Gates auto-create: comparing against a live
    /// recomputation could misread metrics drift as a user edit.
    private var ambientBaseline: PersistedLayout?

    /// The out-of-player editor instance sets these; the player
    /// singleton never does.
    private(set) var isEditorInstance = false
    private(set) var editorProfileName: String?

    /// Editor instances inject synthetic metrics; nil uses the live
    /// screen state.
    var metricsOverride: TouchZoneMetrics?

    /// True when the active game ships an accepted manifest with a `touch` section.
    var hasManifestTouchSection: Bool {
        activeManifest?.touch != nil
    }

    var resetConfirmationTitle: String {
        if case .pinnedProfile = provenance {
            return "Stop using the profile"
        }
        return hasManifestTouchSection ? "Reset to game default" : "Reset to Empo default"
    }

    var resetConfirmationMessage: String {
        if case .pinnedProfile(let name) = provenance {
            return "This game stops using the profile \(name). The profile keeps its layout."
        }
        return "This removes your custom layout."
    }

    private static let controlsManifestLogFile = "controls.json.log"
    private static let separationLogFile = "controls.json.log"

    /// Dedupes display-time separation log lines per layout + geometry signature.
    private var separationLogSignature: String?

    /// Current device orientation as far as the layout is concerned.
    /// PlayerView updates this via `setOrientation(_:)` when geometry
    /// flips. An orientation change saves the current "active" values
    /// into the matching snapshot before it loads the other.
    private(set) var currentOrientation: ControlsOrientation = .portrait

    // MARK: - Oriented control state

    /// One orientation's complete control set. The ACTIVE
    /// orientation lives in `active` (views read and write it
    /// through the forwarding properties below); the other lives in
    /// `inactive`. `setOrientation(_:)` swaps the two values whole,
    /// undo snapshots copy `active`, and resets assign whole
    /// values — a new field pays its cost here once, not at twenty
    /// call sites.
    struct OrientedControls: Equatable {
        var dpadRelativeCenter: CGPoint
        var dpadSize: CGFloat = ControlsLayout.defaultDPadSize
        var dpadOpacity: Double = 1.0
        var dpadStyle: MovementStyle = .dpad
        var buttons: [ButtonModel]
        var actionButtons: [ActionButtonModel] = []
    }

    private var active = OrientedControls(
        dpadRelativeCenter: ControlsLayout.defaultDPadCenterPortrait, buttons: [])
    private var inactive = OrientedControls(
        dpadRelativeCenter: ControlsLayout.defaultDPadCenterLandscape,
        buttons: ControlsLayout.defaultButtonsLandscape)

    // Views read/write these directly; they forward to `active`.
    var dpadRelativeCenter: CGPoint {
        get { active.dpadRelativeCenter }
        set { active.dpadRelativeCenter = newValue }
    }
    var dpadSize: CGFloat {
        get { active.dpadSize }
        set { active.dpadSize = newValue }
    }
    var dpadOpacity: Double {
        get { active.dpadOpacity }
        set { active.dpadOpacity = newValue }
    }
    var dpadStyle: MovementStyle {
        get { active.dpadStyle }
        set { active.dpadStyle = newValue }
    }
    var buttons: [ButtonModel] {
        get { active.buttons }
        set { active.buttons = newValue }
    }
    var actionButtons: [ActionButtonModel] {
        get { active.actionButtons }
        set { active.actionButtons = newValue }
    }

    /// The add UI gates on the loader's cap, so a saved layout
    /// can never fail V015 on its next load.
    var combinedButtonCount: Int { buttons.count + actionButtons.count }

    // MARK: - Edit-session undo (in-memory only, never persisted)

    private static let maxEditUndoDepth = 50

    private var editUndoStack: [OrientedControls] = []
    private var editSessionActive = false

    var canUndo: Bool { editSessionActive && !editUndoStack.isEmpty }

    private init() {
        applyDefaultsForCurrentOrientation()
        observeProfileNotifications()
    }

    /// Out-of-player profile editor instance. It never binds a game,
    /// never runs `save()`, and writes only through `editorSave()`.
    init(editorForProfile name: String, metrics: TouchZoneMetrics) {
        isEditorInstance = true
        editorProfileName = name
        metricsOverride = metrics
        applyDefaultsForCurrentOrientation()
        observeProfileNotifications()
        reloadEditorProfile()
    }

    /// Read-only viewer for the built-in layout: an editor instance
    /// with no backing profile, so every write path is inert. The
    /// built-ins never change, so it observes nothing.
    init(viewerForBuiltins metrics: TouchZoneMetrics) {
        isEditorInstance = true
        metricsOverride = metrics
        applyDefaultsForCurrentOrientation()
    }

    // nonisolated(unsafe): written once on the main actor at init,
    // read in deinit (which is nonisolated by definition).
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    private func observeProfileNotifications() {
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .layoutProfileDidChange, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.handleProfileChange(note)
                }
            })
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .layoutPinDidChange, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.handlePinChange(note)
                }
            })
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// A save never re-resolves the saving instance: posts carry the
    /// originator and self-originated posts are ignored.
    private func handleProfileChange(_ note: Notification) {
        guard note.object as AnyObject? !== self else { return }
        guard let name = note.userInfo?["name"] as? String else { return }
        if isEditorInstance {
            if editorProfileName == name, !editSessionActive {
                reloadEditorProfile()
            }
            return
        }
        guard !editSessionActive, let container = currentContainer else { return }
        switch provenance {
        case .pinnedProfile(let winning) where winning == name,
            .defaultProfile(let winning) where winning == name:
            staggerGeneration += 1
            resolveChain(container: container)
        default:
            break
        }
    }

    private func handlePinChange(_ note: Notification) {
        guard note.object as AnyObject? !== self, !isEditorInstance else { return }
        guard !editSessionActive, let container = currentContainer else { return }
        guard note.userInfo?["gameID"] as? String == currentGameID else { return }
        staggerGeneration += 1
        resolveChain(container: container)
    }

    /// Fresh undo history for a new edit-controls session.
    func beginEditSession() {
        editUndoStack.removeAll()
        editSessionActive = true
    }

    func endEditSession() {
        editSessionActive = false
    }

    private func clearEditUndoStack() {
        editUndoStack.removeAll()
    }

    /// Push the active orientation's layout before a user-initiated
    /// edit. No-op outside an edit session.
    func recordEditSnapshot() {
        guard editSessionActive else { return }
        editUndoStack.append(active)
        if editUndoStack.count > Self.maxEditUndoDepth {
            editUndoStack.removeFirst(editUndoStack.count - Self.maxEditUndoDepth)
        }
    }

    func undoLastEdit() {
        guard let snapshot = editUndoStack.popLast() else { return }
        staggerGeneration += 1
        withAnimation(Motion.standard) {
            active = snapshot
        }
    }

    /// Bind the layout instance to a specific game's stored layout.
    /// `AppState.selectGame(_:)` calls this when a game starts.
    /// `returnToLibrary()` calls it again with `nil` when the user
    /// exits.
    func switchGame(id newGameID: String?, container: GameContainer?, title: String? = nil) {
        if currentGameID != nil {
            save()
        }
        editSessionActive = false
        clearEditUndoStack()
        staggerGeneration += 1
        currentGameID = newGameID
        currentContainer = container
        currentGameTitle = title
        profileRejectionErrorCount = 0
        pinFellThrough = false
        importOfferPending = false
        separationLogSignature = nil
        activeManifestSource = nil
        resolutionInvolvesDerivation = false
        loadManifest(from: container?.gameURL)
        if let container, newGameID != nil {
            migrateLegacyPersistenceIfNeeded(container: container)
            ControllerMapStore.migrateRenamedActions(container: container)
            runProfileMigration(container: container)
            resolveChain(container: container)
            return
        }
        provenance = .builtin
        ambientBaseline = nil
        applyDefaultsForCurrentOrientation()
    }

    /// Switch the active orientation. Snapshot the current "active"
    /// values into the matching slot, then load the other slot's
    /// values back into the active properties.
    ///
    /// No-op if `new == currentOrientation`. PlayerView's
    /// `.onChange(of: isPortrait)` calls this so the layout follows
    /// device rotation in real time.
    func setOrientation(_ new: ControlsOrientation) {
        guard new != currentOrientation else { return }

        clearEditUndoStack()
        staggerGeneration += 1

        swap(&active, &inactive)
        currentOrientation = new
    }

    /// Re-resolve the chain when `gameRect` updates. Only translated
    /// or derived game-shipped layouts are metrics-dependent;
    /// materialized profiles and the builtin are not, so other
    /// provenances skip the churn (auto-create compares against the
    /// baseline SNAPSHOT, so drift cannot mint a profile either way).
    func refreshForGameGeometryChange() {
        guard let container = currentContainer, !isEditorInstance else { return }
        guard !editSessionActive else { return }
        guard provenance == .gameLayout else { return }

        staggerGeneration += 1
        separationLogSignature = nil

        loadManifest(from: container.gameURL)
        resolveChain(container: container)
    }

    private nonisolated static func orientedInput(
        dpadCenter: CGPoint,
        dpadSize: CGFloat,
        dpadOpacity: Double,
        dpadStyle: MovementStyle,
        buttons: [ButtonModel],
        actionButtons: [ActionButtonModel] = []
    ) -> ControlsManifestSerializer.TouchOrientedInput {
        ControlsManifestSerializer.TouchOrientedInput(
            dpadX: Double(dpadCenter.x),
            dpadY: Double(dpadCenter.y),
            dpadSize: Double(dpadSize),
            dpadOpacity: dpadOpacity,
            dpadStyle: dpadStyle,
            buttons: buttons.map { button in
                ControlsManifestSerializer.TouchButtonInput(
                    label: button.label,
                    scancode: button.scancode,
                    x: Double(button.relativeCenter.x),
                    y: Double(button.relativeCenter.y),
                    size: Double(button.size),
                    opacity: button.opacity
                )
            },
            actionButtons: actionButtons.map { button in
                ControlsManifestSerializer.TouchActionButtonInput(
                    action: button.action,
                    x: Double(button.relativeCenter.x),
                    y: Double(button.relativeCenter.y),
                    size: Double(button.size),
                    opacity: button.opacity
                )
            }
        )
    }

    // MARK: - Defaults
    //
    // Default constants are `nonisolated` so legacy migration paths can
    // read them without a hop to the main actor. They're plain Swift
    // `let`s of value types, so any thread can read them safely.

    nonisolated static let defaultDPadCenterPortrait = CGPoint(x: 0.13, y: 0.72)
    nonisolated static let defaultDPadCenterLandscape = CGPoint(x: 0.10, y: 0.65)
    nonisolated static let defaultDPadSize: CGFloat = 140

    /// Legacy alias. Some imports / migration paths still reference
    /// `defaultDPadCenter` (singular). Keep it pointed at the
    /// portrait default so callers without orientation context get
    /// the more common case.
    nonisolated static let defaultDPadCenter = defaultDPadCenterPortrait

    /// 2x2 button grid in the bottom-right of a portrait viewport.
    nonisolated static let defaultButtonsPortrait: [ButtonModel] = [
        ButtonModel(
            label: "Enter", scancode: Int32(MKXP_SCANCODE_RETURN),
            relativeCenter: CGPoint(x: 0.70, y: 0.67),
            size: 56),
        ButtonModel(
            label: "Escape", scancode: Int32(MKXP_SCANCODE_ESCAPE),
            relativeCenter: CGPoint(x: 0.88, y: 0.67),
            size: 56),
        ButtonModel(
            label: "Z", scancode: Int32(MKXP_SCANCODE_Z), relativeCenter: CGPoint(x: 0.70, y: 0.76),
            size: 56),
        ButtonModel(
            label: "B", scancode: Int32(MKXP_SCANCODE_B), relativeCenter: CGPoint(x: 0.88, y: 0.76),
            size: 56),
    ]

    /// 2x2 button grid in the bottom-right of a landscape viewport.
    /// Shorter screen height + wider screen width means the grid
    /// can sit higher and more spread out without overlapping the
    /// game viewport's center.
    nonisolated static let defaultButtonsLandscape: [ButtonModel] = [
        ButtonModel(
            label: "Enter", scancode: Int32(MKXP_SCANCODE_RETURN),
            relativeCenter: CGPoint(x: 0.80, y: 0.59),
            size: 56),
        ButtonModel(
            label: "Escape", scancode: Int32(MKXP_SCANCODE_ESCAPE),
            relativeCenter: CGPoint(x: 0.88, y: 0.59),
            size: 56),
        ButtonModel(
            label: "Z", scancode: Int32(MKXP_SCANCODE_Z), relativeCenter: CGPoint(x: 0.80, y: 0.75),
            size: 56),
        ButtonModel(
            label: "B", scancode: Int32(MKXP_SCANCODE_B), relativeCenter: CGPoint(x: 0.88, y: 0.75),
            size: 56),
    ]

    /// Legacy alias for callers that grab "the" defaults without
    /// orientation. Returns the portrait set.
    nonisolated static var defaultButtons: [ButtonModel] { defaultButtonsPortrait }

    // MARK: - Reset

    /// Reset per provenance. Pinned: the game UNPINS — the profile
    /// keeps its contents, so a reset can never rewrite every game
    /// sharing it — and the layout animates to the ambient chain
    /// result. Ambient: an in-memory reset to the ambient baseline,
    /// with no disk side effect.
    func resetToResolvedDefault() {
        guard !isEditorInstance else { return }
        recordEditSnapshot()

        if case .pinnedProfile = provenance, let container = currentContainer {
            LayoutProfilesManager.store.writePin(.followChain, forGameFolder: container.url)
            if let gameID = currentGameID {
                LayoutProfilesManager.postPinChange(gameID: gameID, from: self)
            }
            pinFellThrough = false
            profileRejectionErrorCount = 0
            provenance = ambientProvenance()
            // Undo restores the layout but not the pin, and the next
            // commit would mint a fork instead. A confirm-gated reset
            // is a clean break: no undo across it.
            clearEditUndoStack()
        }

        let resolved = ambientResolved()
        ambientBaseline = resolved

        let activeResolved: PersistedLayout.Oriented
        let inactiveResolved: PersistedLayout.Oriented
        switch currentOrientation {
        case .portrait:
            activeResolved = resolved.portrait
            inactiveResolved = resolved.landscape
        case .landscape:
            activeResolved = resolved.landscape
            inactiveResolved = resolved.portrait
        }

        inactive = Self.orientedControls(from: inactiveResolved)

        animateReset(
            toButtons: activeResolved.buttons,
            toActionButtons: activeResolved.actionButtons ?? [],
            dpadCenter: CGPoint(x: activeResolved.dpad.rx, y: activeResolved.dpad.ry),
            targetDpadSize: activeResolved.dpad.size,
            targetDpadOpacity: activeResolved.dpad.opacity ?? 1.0,
            targetDpadStyle: activeResolved.dpad.style
        )
    }

    /// Factory state for BOTH orientations (reset = factory state
    /// for this game).
    func resetToDefaults() {
        applyDefaultsForCurrentOrientation()
    }

    /// The struct defaults carry size, opacity, style, and action
    /// buttons; only the per-orientation d-pad center and button
    /// set differ.
    private static func defaultControls(
        for orientation: ControlsOrientation
    ) -> OrientedControls {
        OrientedControls(
            dpadRelativeCenter: orientation == .portrait
                ? defaultDPadCenterPortrait : defaultDPadCenterLandscape,
            buttons: orientation == .portrait
                ? defaultButtonsPortrait : defaultButtonsLandscape)
    }

    private static func orientedControls(
        from oriented: PersistedLayout.Oriented
    ) -> OrientedControls {
        OrientedControls(
            dpadRelativeCenter: CGPoint(x: oriented.dpad.rx, y: oriented.dpad.ry),
            dpadSize: oriented.dpad.size,
            dpadOpacity: oriented.dpad.opacity ?? 1.0,
            dpadStyle: oriented.dpad.style,
            buttons: oriented.buttons,
            actionButtons: oriented.actionButtons ?? [])
    }

    private func applyDefaultsForCurrentOrientation() {
        active = Self.defaultControls(for: currentOrientation)
        inactive = Self.defaultControls(
            for: currentOrientation == .portrait ? .landscape : .portrait)
    }

    private func animateReset(
        toButtons targetButtons: [ButtonModel],
        toActionButtons targetActionButtons: [ActionButtonModel],
        dpadCenter: CGPoint,
        targetDpadSize: CGFloat,
        targetDpadOpacity: Double,
        targetDpadStyle: MovementStyle
    ) {
        var matchedIDs = Set<UUID>()
        var matchedTargets = Set<Int>()

        var moves: [(id: UUID, center: CGPoint, size: CGFloat)] = []
        for (ti, target) in targetButtons.enumerated() {
            guard
                let current = buttons.first(where: {
                    $0.label == target.label && $0.scancode == target.scancode
                        && !matchedIDs.contains($0.id)
                })
            else { continue }

            matchedIDs.insert(current.id)
            matchedTargets.insert(ti)

            let posChanged =
                abs(current.relativeCenter.x - target.relativeCenter.x) > 0.001
                || abs(current.relativeCenter.y - target.relativeCenter.y) > 0.001
            let sizeChanged = abs(current.size - target.size) > 0.5
            if posChanged || sizeChanged {
                moves.append((current.id, target.relativeCenter, target.size))
            }
        }

        // Action buttons match by action id (they have no label or
        // scancode).
        var matchedActionIDs = Set<UUID>()
        var matchedActionTargets = Set<Int>()
        var actionMoves: [(id: UUID, center: CGPoint, size: CGFloat)] = []
        for (ti, target) in targetActionButtons.enumerated() {
            guard
                let current = actionButtons.first(where: {
                    $0.action == target.action && !matchedActionIDs.contains($0.id)
                })
            else { continue }

            matchedActionIDs.insert(current.id)
            matchedActionTargets.insert(ti)

            let posChanged =
                abs(current.relativeCenter.x - target.relativeCenter.x) > 0.001
                || abs(current.relativeCenter.y - target.relativeCenter.y) > 0.001
            let sizeChanged = abs(current.size - target.size) > 0.5
            if posChanged || sizeChanged {
                actionMoves.append((current.id, target.relativeCenter, target.size))
            }
        }

        withAnimation(Motion.standard) {
            buttons.removeAll { !matchedIDs.contains($0.id) }
            for move in moves {
                updateButton(id: move.id, size: move.size, relativeCenter: move.center)
            }
            actionButtons.removeAll { !matchedActionIDs.contains($0.id) }
            for move in actionMoves {
                updateActionButton(id: move.id, size: move.size, relativeCenter: move.center)
            }
            dpadRelativeCenter = dpadCenter
            dpadSize = targetDpadSize
            dpadOpacity = targetDpadOpacity
            dpadStyle = targetDpadStyle
        }

        let missingActions = targetActionButtons.enumerated()
            .filter { !matchedActionTargets.contains($0.offset) }
            .map(\.element)

        let missing = targetButtons.enumerated()
            .filter { !matchedTargets.contains($0.offset) }
            .sorted {
                if $0.element.relativeCenter.y != $1.element.relativeCenter.y {
                    return $0.element.relativeCenter.y < $1.element.relativeCenter.y
                }
                return $0.element.relativeCenter.x < $1.element.relativeCenter.x
            }

        staggerGeneration += 1
        let generation = staggerGeneration
        for (i, (_, button)) in missing.enumerated() {
            let delay = Motion.controlsAppearDelay + Double(i) * Motion.staggerMedium
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard generation == staggerGeneration else { return }
                withAnimation(Motion.gentle) {
                    buttons.append(button)
                }
            }
        }
        for (i, button) in missingActions.enumerated() {
            let delay =
                Motion.controlsAppearDelay + Double(missing.count + i) * Motion.staggerMedium
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard generation == staggerGeneration else { return }
                withAnimation(Motion.gentle) {
                    actionButtons.append(button)
                }
            }
        }
    }

    /// Each wholesale layout replacement (undo, orientation flip,
    /// game switch) bumps this. Pending stagger-add tasks from an
    /// earlier reset then cannot append onto the new state.
    private var staggerGeneration = 0

    // MARK: - Display-time button separation

    /// Single choke point for resolved button centers at display resolution.
    /// Maps each fraction center through the same transform the renderer
    /// uses (`ControlsZone.absolutePosition`, with safe-area and
    /// toolbar-line clamping) and only then runs `ButtonSeparation`.
    /// Separation in any earlier space misses overlaps that the clamp
    /// brings back (e.g. rows that collapse onto controlsMinY). Covers
    /// manifest, translated, user, and builtin layouts alike, and never
    /// persists adjusted positions. Returns final absolute positions.
    func separatedDisplayPositions(
        for geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat,
        includeActionButton: (ActionButtonModel) -> Bool = { _ in true }
    ) -> [UUID: CGPoint] {
        // Hidden action buttons (unavailable during play) must not
        // take part, or an invisible button pushes visible ones away.
        let visibleActionButtons = actionButtons.filter(includeActionButton)
        guard buttons.count + visibleActionButtons.count > 0, geoSize.width > 0,
            geoSize.height > 0
        else { return [:] }

        // Both button collections feed one separation pass. Input
        // order is buttons, then action buttons; the id mapping at
        // the end follows the same order.
        let allCircles: [(id: UUID, center: CGPoint, size: CGFloat)] =
            buttons.map { ($0.id, $0.relativeCenter, $0.size) }
            + visibleActionButtons.map { ($0.id, $0.relativeCenter, $0.size) }

        let inputs = allCircles.map { circle -> (x: Double, y: Double, size: Double) in
            let clamped = ControlsZone.absolutePosition(
                for: circle.center, in: geoSize,
                controlSize: CGSize(width: circle.size, height: circle.size),
                safeArea: safeArea, controlsMinY: controlsMinY
            )
            return (x: Double(clamped.x), y: Double(clamped.y), size: Double(circle.size))
        }

        let dpadClamped = ControlsZone.absolutePosition(
            for: dpadRelativeCenter, in: geoSize,
            controlSize: CGSize(width: dpadSize, height: dpadSize),
            safeArea: safeArea, controlsMinY: controlsMinY
        )
        let obstacles = [
            (x: Double(dpadClamped.x), y: Double(dpadClamped.y), size: Double(dpadSize))
        ]

        let result = ButtonSeparation.separate(
            inputs,
            width: Double(geoSize.width),
            height: Double(geoSize.height),
            obstacles: obstacles
        )

        if result.movedCount > 0 {
            let signature =
                "\(result.movedCount)-\(Int(geoSize.width))x\(Int(geoSize.height))-\(allCircles.count)"
            if separationLogSignature != signature, let container = currentContainer {
                separationLogSignature = signature
                container.appendLogLine(
                    "controls: separated \(result.movedCount) overlapping buttons",
                    fileName: Self.separationLogFile
                )
            }
        }

        var centers: [UUID: CGPoint] = [:]
        for (index, circle) in allCircles.enumerated() {
            let point = result.positions[index]
            centers[circle.id] = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        return centers
    }

    // MARK: - Persistence

    /// Persist edits per provenance. A pinned profile takes the
    /// write-back; ambient sources are derive-only — the first
    /// committed change in an edit session creates a profile, pins
    /// the game, and updates provenance in place. This never touches
    /// the per-game `EmpoState/controls.json`: its dead touch section
    /// stays byte-identical on disk (copy-not-move), and controller
    /// persistence lives in `ControllerMapStore`.
    func save() {
        if isEditorInstance {
            editorSave()
            return
        }
        guard let container = currentContainer, let gameID = currentGameID else { return }
        let store = LayoutProfilesManager.store

        switch provenance {
        case .pinnedProfile(let name):
            let section = materializedTouchSection()
            if let existing = store.readProfile(name)?.touch {
                let disk = ProfileMaterializer.canonicalBytes(
                    ProfileMaterializer.materialize(
                        user: existing, manifest: nil,
                        builtins: LayoutProfilesManager.builtins(), metrics: layoutMetrics()))
                if ProfileMaterializer.canonicalBytes(section) == disk {
                    return
                }
            }
            store.writeProfile(name, touch: section)
            LayoutProfilesManager.postProfileChange(name: name, from: self)

        case .gameLayout, .defaultProfile, .builtin:
            // Auto-create fires only from edit-session commits, so a
            // crash-teardown save can never mint a profile.
            guard editSessionActive else { return }
            guard let baseline = ambientBaseline else { return }
            let current = currentPersistedLayout()
            if Self.layoutsEquivalent(current.portrait, baseline.portrait),
                Self.layoutsEquivalent(current.landscape, baseline.landscape)
            {
                return
            }
            let base = currentGameTitle ?? container.url.lastPathComponent
            let name = store.uniqueName(base: base)
            guard store.createProfile(name, touch: materializedTouchSection()) else { return }
            store.writePin(.profile(name), forGameFolder: container.url)
            provenance = .pinnedProfile(name)
            pinFellThrough = false
            LayoutProfilesManager.postPinChange(gameID: gameID, from: self)
            LayoutProfilesManager.postProfileChange(name: name, from: self)
        }
    }

    /// The full, both-orientation form profiles store. Never sparse:
    /// a sparse section would resolve against whatever game the
    /// profile is pinned to next.
    func materializedTouchSection() -> TouchSection {
        let layout = currentPersistedLayout()
        return TouchSection(
            portrait: Self.touchLayout(from: layout.portrait),
            landscape: Self.touchLayout(from: layout.landscape)
        )
    }

    /// Editor instances write straight to the profile file.
    func editorSave() {
        guard let name = editorProfileName else { return }
        LayoutProfilesManager.store.writeProfile(name, touch: materializedTouchSection())
        LayoutProfilesManager.postProfileChange(name: name, from: self)
    }

    func reloadEditorProfile() {
        guard let name = editorProfileName,
            let touch = LayoutProfilesManager.store.readProfile(name)?.touch
        else { return }
        applyProfileSection(touch)
    }

    /// The editor renamed its profile (the store rename already ran).
    func editorRenamed(to name: String) {
        guard isEditorInstance else { return }
        editorProfileName = name
    }

    // MARK: - Chain resolution

    private func resolveChain(container: GameContainer) {
        let store = LayoutProfilesManager.store
        let loaded = store.loadPin(forGameFolder: container.url)
        if let note = loaded.note {
            container.appendLogLine(note, fileName: Self.controlsManifestLogFile)
        }

        var pinnedName: String?
        var pinnedRead: LayoutProfileStore.ProfileRead?
        if case .profile(let name) = loaded.pin {
            pinnedName = name
            pinnedRead = store.readProfile(name)
        }
        let defaultName = LayoutProfilesManager.defaultProfileName
        let defaultRead = defaultName.flatMap { store.readProfile($0) }

        let outcome = LayoutChainResolver.resolve(
            pin: loaded.pin,
            levels: LayoutChainResolver.Levels(
                pinnedProfileValid: pinnedName == nil
                    ? nil : (pinnedRead?.invalid == false && pinnedRead?.touch != nil),
                gameLayoutOccupied: activeManifest?.touch != nil,
                defaultProfileValid: defaultName == nil
                    ? nil : (defaultRead?.invalid == false && defaultRead?.touch != nil)
            )
        )

        pinFellThrough = outcome.fellThrough
        profileRejectionErrorCount =
            pinnedRead?.invalid == true ? (pinnedRead?.errorCount ?? 1) : 0

        switch outcome.level {
        case .pinnedProfile:
            provenance = .pinnedProfile(pinnedName ?? "")
            if let touch = pinnedRead?.touch {
                applyProfileSection(touch)
            }
        case .gameLayout:
            provenance = .gameLayout
            // One-time heads-up that the game layout displaced the
            // user's default profile (record §8 wording).
            if loaded.pin == .followChain, defaultName != nil,
                let gameID = currentGameID,
                !Self.shownGameLayoutNotices().contains(gameID)
            {
                gameLayoutNoticePending = true
            }
            applyResolvedLayout()
        case .defaultProfile:
            provenance = .defaultProfile(defaultName ?? "")
            if let touch = defaultRead?.touch {
                applyProfileSection(touch)
            }
        case .builtin:
            provenance = .builtin
            resolutionInvolvesDerivation = false
            applyDefaultsForCurrentOrientation()
        }

        ambientBaseline = ambientResolved()
    }

    /// Profile gaps complete against the builtin only (never a game
    /// manifest — that would leak per-game values into a portable
    /// profile).
    private func applyProfileSection(_ touch: TouchSection) {
        let materialized = ProfileMaterializer.materialize(
            user: touch, manifest: nil,
            builtins: LayoutProfilesManager.builtins(), metrics: layoutMetrics())
        resolutionInvolvesDerivation = false
        let metrics = layoutMetrics()
        let portrait = Self.oriented(
            from: materialized.portrait
                ?? TouchLayout(dpad: nil, buttons: [], actionButtons: []),
            orientation: .portrait, manifest: nil, metrics: metrics)
        let landscape = Self.oriented(
            from: materialized.landscape
                ?? TouchLayout(dpad: nil, buttons: [], actionButtons: []),
            orientation: .landscape, manifest: nil, metrics: metrics)
        applyV2(PersistedLayout(portrait: portrait, landscape: landscape))
    }

    private func ambientProvenance() -> LayoutProvenance {
        if activeManifest?.touch != nil { return .gameLayout }
        if let name = LayoutProfilesManager.defaultProfileName,
            let read = LayoutProfilesManager.store.readProfile(name),
            !read.invalid, read.touch != nil
        {
            return .defaultProfile(name)
        }
        return .builtin
    }

    /// What the chain yields with no named pin: the auto-create
    /// baseline.
    private func ambientResolved() -> PersistedLayout {
        let metrics = layoutMetrics()
        if activeManifest?.touch != nil {
            return PersistedLayout(
                portrait: Self.resolveInitialLayout(
                    manifest: activeManifest, orientation: .portrait, metrics: metrics),
                landscape: Self.resolveInitialLayout(
                    manifest: activeManifest, orientation: .landscape, metrics: metrics)
            )
        }
        if let defaultName = LayoutProfilesManager.defaultProfileName,
            let read = LayoutProfilesManager.store.readProfile(defaultName),
            !read.invalid, let touch = read.touch
        {
            let materialized = ProfileMaterializer.materialize(
                user: touch, manifest: nil,
                builtins: LayoutProfilesManager.builtins(), metrics: metrics)
            return PersistedLayout(
                portrait: Self.oriented(
                    from: materialized.portrait
                        ?? TouchLayout(dpad: nil, buttons: [], actionButtons: []),
                    orientation: .portrait, manifest: nil, metrics: metrics),
                landscape: Self.oriented(
                    from: materialized.landscape
                        ?? TouchLayout(dpad: nil, buttons: [], actionButtons: []),
                    orientation: .landscape, manifest: nil, metrics: metrics)
            )
        }
        return PersistedLayout(
            portrait: Self.builtinOriented(
                dpadCenter: Self.defaultDPadCenterPortrait, buttons: Self.defaultButtonsPortrait),
            landscape: Self.builtinOriented(
                dpadCenter: Self.defaultDPadCenterLandscape, buttons: Self.defaultButtonsLandscape)
        )
    }

    private func layoutMetrics() -> TouchZoneMetrics {
        metricsOverride ?? Self.touchZoneMetricsForManifestLoad()
    }

    // MARK: - Profile migration

    private func runProfileMigration(container: GameContainer) {
        let store = LayoutProfilesManager.store
        let recordURL = LayoutProfilesManager.profilesRootURL
            .appendingPathComponent(MigrationRecord.fileName)
        var record =
            (try? Data(contentsOf: recordURL)).map(MigrationRecord.parse)
            ?? MigrationRecord()
        let builtins = LayoutProfilesManager.builtins()

        // An invalid per-game file yields no touch section here and
        // stays on disk untouched — but its findings still reach the
        // game's log, like the old per-game load path.
        let userLoad = UserControlsFile.load(in: container)
        if let findings = userLoad?.findings, !findings.isEmpty {
            UserControlsFile.logFindings(findings, container: container)
        }
        let userTouch = userLoad?.manifest?.touch
        let pinExists = FileManager.default.fileExists(
            atPath: store.pinURL(forGameFolder: container.url).path)

        let action = ProfileMigration.decide(
            context: ProfileMigration.Context(
                gameID: container.id,
                gameTitle: currentGameTitle ?? container.url.lastPathComponent,
                userTouch: userTouch,
                manifestTouch: activeManifest?.touch,
                pinFileExists: pinExists,
                record: record,
                existingProfiles: store.listProfiles(),
                profileCanonicalBytes: { name in
                    guard let touch = store.readProfile(name)?.touch else { return nil }
                    return ProfileMaterializer.canonicalBytes(
                        ProfileMaterializer.materialize(
                            user: touch, manifest: nil, builtins: builtins,
                            metrics: .reference))
                }
            ),
            builtins: builtins
        )

        switch action {
        case .none:
            return
        case .importOffer:
            importOfferPending = true
            return
        case .recordOnly(let hash):
            record.games[container.id] = MigrationRecord.Entry(hash: hash, profile: nil)
        case .createAndPin(let baseName, let hash):
            let materialized = ProfileMaterializer.materialize(
                user: userTouch, manifest: activeManifest?.touch,
                builtins: builtins, metrics: .reference)
            let name = store.uniqueName(base: baseName)
            guard store.createProfile(name, touch: materialized) else { return }
            store.writePin(.profile(name), forGameFolder: container.url)
            record.games[container.id] = MigrationRecord.Entry(hash: hash, profile: name)
        case .pinToExisting(let profile, let renameToShared, let hash):
            var target = profile
            if renameToShared {
                let count = store.gamesPinned(to: profile).count + 1
                let shared = store.uniqueName(base: "Shared layout (\(count) games)")
                if LayoutProfilesManager.renameProfile(from: profile, to: shared) {
                    target = shared
                    for (gameID, entry) in record.games where entry.profile == profile {
                        record.games[gameID]?.profile = shared
                    }
                }
            }
            store.writePin(.profile(target), forGameFolder: container.url)
            record.games[container.id] = MigrationRecord.Entry(hash: hash, profile: target)
        }
        try? record.serialize().write(to: recordURL, options: .atomic)
    }

    /// The user accepted the import offer: the changed per-game file
    /// becomes a pinned profile.
    func acceptImportOffer() {
        guard let container = currentContainer, importOfferPending else { return }
        importOfferPending = false
        let store = LayoutProfilesManager.store
        let builtins = LayoutProfilesManager.builtins()
        let importLoad = UserControlsFile.load(in: container)
        if let findings = importLoad?.findings, !findings.isEmpty {
            UserControlsFile.logFindings(findings, container: container)
        }
        guard let userTouch = importLoad?.manifest?.touch else { return }
        let materialized = ProfileMaterializer.materialize(
            user: userTouch, manifest: activeManifest?.touch,
            builtins: builtins, metrics: .reference)
        let name = store.uniqueName(
            base: currentGameTitle ?? container.url.lastPathComponent)
        guard store.createProfile(name, touch: materialized) else { return }
        store.writePin(.profile(name), forGameFolder: container.url)

        let recordURL = LayoutProfilesManager.profilesRootURL
            .appendingPathComponent(MigrationRecord.fileName)
        var record =
            (try? Data(contentsOf: recordURL)).map(MigrationRecord.parse)
            ?? MigrationRecord()
        record.games[container.id] = MigrationRecord.Entry(
            hash: FNV1a.hash64(ProfileMaterializer.canonicalBytes(materialized)),
            profile: name)
        try? record.serialize().write(to: recordURL, options: .atomic)

        resolveChain(container: container)
    }

    func dismissImportOffer() {
        importOfferPending = false
    }

    private static let gameLayoutNoticeKey = "layoutProfiles.gameNoticeShown"

    private static func shownGameLayoutNotices() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: gameLayoutNoticeKey) ?? [])
    }

    func dismissGameLayoutNotice() {
        gameLayoutNoticePending = false
        guard let gameID = currentGameID else { return }
        var shown = Self.shownGameLayoutNotices()
        shown.insert(gameID)
        UserDefaults.standard.set(Array(shown).sorted(), forKey: Self.gameLayoutNoticeKey)
    }

    private static func persistedOriented(
        from controls: OrientedControls
    ) -> PersistedLayout.Oriented {
        PersistedLayout.Oriented(
            dpad: .init(
                rx: controls.dpadRelativeCenter.x, ry: controls.dpadRelativeCenter.y,
                size: controls.dpadSize, opacity: controls.dpadOpacity,
                style: controls.dpadStyle
            ),
            buttons: controls.buttons,
            actionButtons: controls.actionButtons
        )
    }

    private func currentPersistedLayout() -> PersistedLayout {
        let activeOriented = Self.persistedOriented(from: active)
        let inactiveOriented = Self.persistedOriented(from: inactive)
        switch currentOrientation {
        case .portrait:
            return PersistedLayout(portrait: activeOriented, landscape: inactiveOriented)
        case .landscape:
            return PersistedLayout(portrait: inactiveOriented, landscape: activeOriented)
        }
    }

    /// Equality that ignores `ButtonModel.id`. resolveInitialLayout mints
    /// fresh UUIDs per call, so synthesized == would treat every
    /// manifest-derived layout as customized.
    private static func layoutsEquivalent(
        _ a: PersistedLayout.Oriented,
        _ b: PersistedLayout.Oriented
    ) -> Bool {
        guard a.dpad == b.dpad, a.buttons.count == b.buttons.count else { return false }
        let aActions = a.actionButtons ?? []
        let bActions = b.actionButtons ?? []
        guard aActions.count == bActions.count else { return false }
        guard
            zip(aActions, bActions).allSatisfy({ lhs, rhs in
                lhs.action == rhs.action
                    && lhs.relativeCenter == rhs.relativeCenter
                    && lhs.size == rhs.size && lhs.opacity == rhs.opacity
            })
        else { return false }
        return zip(a.buttons, b.buttons).allSatisfy { lhs, rhs in
            lhs.label == rhs.label && lhs.scancode == rhs.scancode
                && lhs.relativeCenter == rhs.relativeCenter
                && lhs.size == rhs.size && lhs.opacity == rhs.opacity
        }
    }

    private static func touchLayout(from oriented: PersistedLayout.Oriented) -> TouchLayout {
        // The serializer omits the style line for .dpad, so passing
        // the concrete value keeps existing files byte-stable.
        let dpad = DPadSpec(
            x: Double(oriented.dpad.rx),
            y: Double(oriented.dpad.ry),
            size: Double(oriented.dpad.size),
            opacity: oriented.dpad.opacity,
            style: oriented.dpad.style
        )
        let buttons = oriented.buttons.compactMap { button -> ButtonSpec? in
            guard let key = KeyCodeTable.code(for: button.scancode) else { return nil }
            return ButtonSpec(
                label: button.label.isEmpty ? nil : button.label,
                key: key,
                x: Double(button.relativeCenter.x),
                y: Double(button.relativeCenter.y),
                size: Double(button.size),
                opacity: button.opacity
            )
        }
        // Always non-nil: an omitted key means "inherit the shipped
        // action buttons" at load, so a user who deleted them all
        // must save an explicit [].
        let actionButtons = (oriented.actionButtons ?? []).map { button in
            ActionButtonSpec(
                action: button.action,
                x: Double(button.relativeCenter.x),
                y: Double(button.relativeCenter.y),
                size: Double(button.size),
                opacity: button.opacity
            )
        }
        return TouchLayout(dpad: dpad, buttons: buttons, actionButtons: actionButtons)
    }

    private static func oriented(
        from touchLayout: TouchLayout,
        orientation: ControlsOrientation,
        manifest: ControlsManifest?,
        metrics: TouchZoneMetrics
    ) -> PersistedLayout.Oriented {
        let fallback = resolveInitialLayout(
            manifest: manifest, orientation: orientation, metrics: metrics)

        let dpad: PersistedLayout.DPad
        if let spec = touchLayout.dpad {
            dpad = PersistedLayout.DPad(
                rx: CGFloat(spec.x),
                ry: CGFloat(spec.y),
                size: CGFloat(spec.size ?? 140),
                opacity: spec.opacity ?? 1.0,
                style: spec.style
            )
        } else {
            dpad = fallback.dpad
        }

        let buttons: [ButtonModel]
        if let specs = touchLayout.buttons {
            buttons = specs.compactMap { spec in
                guard let scancode = KeyCodeTable.scancode(for: spec.key) else { return nil }
                let label = spec.label ?? KeyCodeTable.displayName(for: spec.key) ?? spec.key
                return ButtonModel(
                    label: label,
                    scancode: scancode,
                    relativeCenter: CGPoint(x: spec.x, y: spec.y),
                    size: CGFloat(spec.size ?? 56),
                    opacity: spec.opacity ?? 1.0
                )
            }
        } else {
            buttons = fallback.buttons
        }

        let actionButtons: [ActionButtonModel]?
        if let specs = touchLayout.actionButtons {
            actionButtons = specs.map(Self.actionButtonModel(from:))
        } else {
            actionButtons = fallback.actionButtons
        }

        return PersistedLayout.Oriented(
            dpad: dpad, buttons: buttons, actionButtons: actionButtons)
    }

    private static func actionButtonModel(from spec: ActionButtonSpec) -> ActionButtonModel {
        ActionButtonModel(
            action: spec.action,
            relativeCenter: CGPoint(x: spec.x, y: spec.y),
            size: CGFloat(spec.size ?? 56),
            opacity: spec.opacity ?? 1.0
        )
    }

    /// One-time migration from UserDefaults layout/controller keys.
    private func migrateLegacyPersistenceIfNeeded(container: GameContainer) {
        guard !UserControlsFile.exists(in: container) else { return }

        let layoutKey = DefaultsKey.controlsLayout(gameID: container.id)
        let mapKey = DefaultsKey.controllerMap(gameID: container.id)
        let layoutData = UserDefaults.standard.data(forKey: layoutKey)
        let hasMap = UserDefaults.standard.data(forKey: mapKey) != nil
        guard layoutData != nil || hasMap else { return }

        let touch: TouchSection?
        if let layoutData, let layout = decodeLegacyLayout(data: layoutData) {
            touch = ControlsManifestSerializer.touchSection(
                portrait: Self.orientedInput(
                    dpadCenter: CGPoint(x: layout.portrait.dpad.rx, y: layout.portrait.dpad.ry),
                    dpadSize: layout.portrait.dpad.size,
                    dpadOpacity: layout.portrait.dpad.opacity ?? 1.0,
                    dpadStyle: .dpad,
                    buttons: layout.portrait.buttons
                ),
                landscape: Self.orientedInput(
                    dpadCenter: CGPoint(x: layout.landscape.dpad.rx, y: layout.landscape.dpad.ry),
                    dpadSize: layout.landscape.dpad.size,
                    dpadOpacity: layout.landscape.dpad.opacity ?? 1.0,
                    dpadStyle: .dpad,
                    buttons: layout.landscape.buttons
                ),
                onDroppedButton: { label, scancode in
                    NSLog(
                        "controls.json: Dropped button \"\(label)\" (scancode \(scancode) has no key name)"
                    )
                }
            )
        } else {
            touch = nil
        }

        let controller = ControllerMapStore.decodeLegacyPerGameMap(gameID: container.id)

        guard touch != nil || controller != nil else { return }

        guard UserControlsFile.write(in: container, touch: touch, controller: controller) else {
            return
        }

        UserDefaults.standard.removeObject(forKey: layoutKey)
        UserDefaults.standard.removeObject(forKey: mapKey)
    }

    private func decodeLegacyLayout(data: Data) -> PersistedLayout? {
        if let v2 = try? JSONDecoder().decode(PersistedLayout.self, from: data) {
            return v2
        }

        if let v1 = try? JSONDecoder().decode(PersistedLayoutV1.self, from: data) {
            let portrait = PersistedLayout.Oriented(dpad: v1.dpad, buttons: v1.buttons)
            let landscape = PersistedLayout.Oriented(
                dpad: .init(
                    rx: Self.defaultDPadCenterLandscape.x,
                    ry: Self.defaultDPadCenterLandscape.y,
                    size: Self.defaultDPadSize,
                    opacity: 1.0,
                    style: .dpad
                ),
                buttons: Self.defaultButtonsLandscape
            )
            return PersistedLayout(portrait: portrait, landscape: landscape)
        }

        return nil
    }

    /// Host metrics for Kirin/JoiPlay translation at manifest load.
    /// Uses live safe area + toolbar geometry when available. The portrait
    /// top falls back to a 4:3 game-bottom estimate when the engine has
    /// not published `gameRect` yet (typical at game select).
    private static func touchZoneMetricsForManifestLoad() -> TouchZoneMetrics {
        let bounds = UIScreen.main.bounds
        let safeArea = AppWindow.currentSafeArea
        let portraitWidth = min(bounds.width, bounds.height)
        let portraitHeight = max(bounds.width, bounds.height)
        let toolbarBtnSize = IconButtonSize.sm.points

        let landscapeTop = ControlsZone.landscapeControlsTopInset(
            safeArea: safeArea, toolbarButtonSize: toolbarBtnSize)
        let bottomInset = Double(safeArea.bottom + ControlsZone.padding)

        let gameRect = EngineState.shared.gameRect
        let portraitTop: Double
        if gameRect.height > 0 {
            portraitTop = Double(
                ControlsZone.toolbarBottomY(
                    isPortrait: true,
                    gameRect: gameRect,
                    safeArea: safeArea,
                    btnSize: toolbarBtnSize,
                    geoHeight: portraitHeight
                ))
        } else {
            // RPG Maker viewports are 4:3. In portrait the game bottom
            // sits at roughly safe-area top + 0.75 × screen width.
            portraitTop = Double(safeArea.top) + portraitWidth * 0.75 + ControlsZone.toolbarGap
        }

        // Landscape lateral insets = the notch / home-indicator depth,
        // which the render clamp reserves on both edges. When currently
        // landscape, the live safe area has the exact values. In
        // portrait the notch depth appears as safeArea.top, so use it
        // as the estimate for both landscape edges.
        let isLandscapeNow = bounds.width > bounds.height
        let landscapeLeading: Double
        let landscapeTrailing: Double
        if isLandscapeNow {
            landscapeLeading = Double(safeArea.leading)
            landscapeTrailing = Double(safeArea.trailing)
        } else {
            landscapeLeading = Double(safeArea.top)
            landscapeTrailing = Double(safeArea.top)
        }

        return TouchZoneMetrics(
            portraitWidth: Double(portraitWidth),
            portraitHeight: Double(portraitHeight),
            landscapeWidth: Double(portraitHeight),
            landscapeHeight: Double(portraitWidth),
            portraitTopInset: portraitTop,
            portraitBottomInset: bottomInset,
            landscapeTopInset: Double(landscapeTop),
            landscapeBottomInset: bottomInset,
            portraitLeadingInset: 0,
            portraitTrailingInset: 0,
            landscapeLeadingInset: landscapeLeading,
            landscapeTrailingInset: landscapeTrailing
        )
    }

    private func loadManifest(from gameRoot: URL?) {
        activeManifest = nil
        activeManifestSource = nil
        manifestRejectionErrorCount = 0
        guard let gameRoot else { return }

        let metrics = Self.touchZoneMetricsForManifestLoad()

        guard let outcome = ControlsManifestLoader.load(gameRoot: gameRoot, metrics: metrics) else {
            return
        }

        let result = outcome.result
        activeManifestSource = result.location
        let logsContainer = GameContainer(url: gameRoot.deletingLastPathComponent())

        if let note = outcome.note {
            logsContainer.appendLogLine(
                Self.logLine(for: note),
                fileName: Self.controlsManifestLogFile
            )
            if note != .rootSkippedBecauseEmpoExists
                && note != .kirinSkippedBecauseManifestExists
                && note != .joiplaySkippedBecauseOtherSourceExists
            {
                return
            }
        }

        if result.ignoredNewerVersion {
            logsContainer.appendLogLine(
                "controls.json: Ignored manifest with version > 1",
                fileName: Self.controlsManifestLogFile
            )
            return
        }

        let logPrefix: String =
            switch result.location {
            case .kirin: "kirin-touch-controls.json:"
            case .joiplay: "gamepad.json:"
            default: "controls.json:"
            }
        for finding in result.findings {
            let severity = finding.severity == .error ? "error" : "warning"
            let line =
                "\(logPrefix) [\(finding.code)] (\(severity)) \(finding.path): \(finding.message)"
            logsContainer.appendLogLine(line, fileName: Self.controlsManifestLogFile)
        }

        if let manifest = result.manifest {
            activeManifest = manifest
            return
        }

        manifestRejectionErrorCount = result.findings.filter { $0.severity == .error }.count
    }

    private static func logLine(for note: ControlsManifestLoader.LoadOutcome.Note) -> String {
        switch note {
        case .rootSkippedBecauseEmpoExists:
            return
                "controls.json: Skipped controls.json at game root; using empo/controls.json"
        case .rootUnclaimedNoVersion:
            return
                "controls.json: Ignored controls.json at game root (no version key; not an Empo manifest)"
        case .rootUnclaimedNotObject:
            return
                "controls.json: Ignored controls.json at game root (not a JSON object; not an Empo manifest)"
        case .rootUnclaimedOversized:
            return
                "controls.json: Ignored controls.json at game root (exceeds 128 KiB; not an Empo manifest)"
        case .kirinSkippedBecauseManifestExists:
            return
                "kirin-touch-controls.json: Skipped (an Empo controls manifest takes precedence)"
        case .joiplaySkippedBecauseOtherSourceExists:
            return
                "gamepad.json: Skipped (a controls manifest or Kirin layout takes precedence)"
        }
    }

    private func applyResolvedLayout() {
        let metrics = Self.touchZoneMetricsForManifestLoad()
        resolutionInvolvesDerivation = false
        if let touch = activeManifest?.touch {
            let completion = Self.completeTouchSection(touch, metrics: metrics)
            resolutionInvolvesDerivation = completion.involvedDerivation
        }
        let portrait = Self.resolveInitialLayout(
            manifest: activeManifest, orientation: .portrait, metrics: metrics)
        let landscape = Self.resolveInitialLayout(
            manifest: activeManifest, orientation: .landscape, metrics: metrics)
        applyV2(PersistedLayout(portrait: portrait, landscape: landscape))
    }

    private static func completeTouchSection(
        _ section: TouchSection,
        metrics: TouchZoneMetrics
    ) -> (section: TouchSection, involvedDerivation: Bool) {
        TouchSectionCompletion.complete(
            section,
            metrics: metrics,
            defaultDpad: defaultDpadSpec
        )
    }

    private static let defaultDpadSpec = TouchSectionCompletion.DefaultDpadSpec(
        portraitX: Double(defaultDPadCenterPortrait.x),
        portraitY: Double(defaultDPadCenterPortrait.y),
        landscapeX: Double(defaultDPadCenterLandscape.x),
        landscapeY: Double(defaultDPadCenterLandscape.y),
        size: Double(defaultDPadSize)
    )

    /// SPEC §9 resolution for one orientation when UserDefaults is absent.
    fileprivate static func resolveInitialLayout(
        manifest: ControlsManifest?,
        orientation: ControlsOrientation,
        metrics: TouchZoneMetrics
    ) -> PersistedLayout.Oriented {
        let builtinDpadCenter: CGPoint
        let builtinButtons: [ButtonModel]
        switch orientation {
        case .portrait:
            builtinDpadCenter = defaultDPadCenterPortrait
            builtinButtons = defaultButtonsPortrait
        case .landscape:
            builtinDpadCenter = defaultDPadCenterLandscape
            builtinButtons = defaultButtonsLandscape
        }

        guard let touch = manifest?.touch else {
            return builtinOriented(
                dpadCenter: builtinDpadCenter, buttons: builtinButtons)
        }

        let completed = completeTouchSection(touch, metrics: metrics).section

        let touchLayout: TouchLayout?
        switch orientation {
        case .portrait:
            touchLayout = completed.portrait
        case .landscape:
            touchLayout = completed.landscape
        }

        guard let touchLayout else {
            return builtinOriented(
                dpadCenter: builtinDpadCenter, buttons: builtinButtons)
        }

        let dpad: PersistedLayout.DPad
        if let spec = touchLayout.dpad {
            dpad = PersistedLayout.DPad(
                rx: CGFloat(spec.x),
                ry: CGFloat(spec.y),
                size: CGFloat(spec.size ?? 140),
                opacity: spec.opacity ?? 1.0,
                style: spec.style
            )
        } else {
            dpad = PersistedLayout.DPad(
                rx: builtinDpadCenter.x,
                ry: builtinDpadCenter.y,
                size: defaultDPadSize,
                opacity: 1.0,
                style: .dpad
            )
        }

        let buttons: [ButtonModel]
        if let specs = touchLayout.buttons {
            buttons = specs.compactMap { spec in
                guard let scancode = KeyCodeTable.scancode(for: spec.key) else { return nil }
                let label = spec.label ?? KeyCodeTable.displayName(for: spec.key) ?? spec.key
                return ButtonModel(
                    label: label,
                    scancode: scancode,
                    relativeCenter: CGPoint(x: spec.x, y: spec.y),
                    size: CGFloat(spec.size ?? 56),
                    opacity: spec.opacity ?? 1.0
                )
            }
        } else {
            buttons = builtinButtons
        }

        // Game-shipped layouts may carry action buttons. Mapping them
        // here keeps the customization diff honest: a shipped action
        // button must not read as a user edit.
        let actionButtons = touchLayout.actionButtons.map { specs in
            specs.map(actionButtonModel(from:))
        }

        return PersistedLayout.Oriented(
            dpad: dpad, buttons: buttons, actionButtons: actionButtons)
    }

    private static func builtinOriented(
        dpadCenter: CGPoint,
        buttons: [ButtonModel]
    ) -> PersistedLayout.Oriented {
        PersistedLayout.Oriented(
            dpad: .init(
                rx: dpadCenter.x,
                ry: dpadCenter.y,
                size: defaultDPadSize,
                opacity: 1.0,
                style: .dpad
            ),
            buttons: buttons,
            actionButtons: nil
        )
    }

    private func applyV2(_ layout: PersistedLayout) {
        switch currentOrientation {
        case .portrait:
            active = Self.orientedControls(from: layout.portrait)
            inactive = Self.orientedControls(from: layout.landscape)
        case .landscape:
            active = Self.orientedControls(from: layout.landscape)
            inactive = Self.orientedControls(from: layout.portrait)
        }
    }

    // MARK: - Mutators

    func addButton(label: String, scancode: Int32) {
        recordEditSnapshot()
        var displayLabel = label
        if let range = label.range(of: " (") {
            displayLabel = String(label[..<range.lowerBound])
        }
        let button = ButtonModel(
            label: displayLabel, scancode: scancode,
            relativeCenter: CGPoint(x: 0.5, y: 0.5), size: 56)
        withAnimation(Motion.gentle) {
            buttons.append(button)
        }
    }

    func removeButton(id: UUID) {
        recordEditSnapshot()
        buttons.removeAll { $0.id == id }
    }

    func addActionButton(action: String) {
        recordEditSnapshot()
        let button = ActionButtonModel(
            action: action,
            relativeCenter: CGPoint(x: 0.5, y: 0.5), size: 56)
        withAnimation(Motion.gentle) {
            actionButtons.append(button)
        }
    }

    func removeActionButton(id: UUID) {
        recordEditSnapshot()
        actionButtons.removeAll { $0.id == id }
    }

    func updateActionButton(
        id: UUID, size: CGFloat? = nil,
        relativeCenter: CGPoint? = nil, opacity: Double? = nil
    ) {
        guard let index = actionButtons.firstIndex(where: { $0.id == id }) else { return }
        if let size { actionButtons[index].size = size }
        if let relativeCenter { actionButtons[index].relativeCenter = relativeCenter }
        if let opacity { actionButtons[index].opacity = opacity }
    }

    func updateButton(
        id: UUID, label: String? = nil, scancode: Int32? = nil, size: CGFloat? = nil,
        relativeCenter: CGPoint? = nil, opacity: Double? = nil
    ) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        if let label { buttons[index].label = label }
        if let scancode { buttons[index].scancode = scancode }
        if let size { buttons[index].size = size }
        if let relativeCenter { buttons[index].relativeCenter = relativeCenter }
        if let opacity { buttons[index].opacity = opacity }
    }
}
