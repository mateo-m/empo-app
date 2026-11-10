// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import GameProbe
import Observation
import SwiftUI
import UIKit

protocol PlacedControl: Identifiable where ID == UUID {
    var relativeCenter: CGPoint { get set }
    var size: CGFloat { get set }
}

struct ButtonModel: PlacedControl, Equatable, Codable {
    let id: UUID
    var label: String
    var scancode: Int32
    var relativeCenter: CGPoint  // fraction of superview size
    var size: CGFloat
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
        self.size =
            try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? CGFloat(ControlLimits.defaultButtonSize)
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

struct ActionButtonModel: PlacedControl, Equatable, Codable {
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
        self.size =
            try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? CGFloat(ControlLimits.defaultButtonSize)
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

/// Each game keeps one layout for each orientation. Fractions do not
/// survive a rotation: a portrait 0.09 vertical gap is 79pt, but on a
/// wide screen it is 37pt and overlaps the 56pt button.
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
        var opacity: Double?
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
        /// Legacy UserDefaults blobs do not have this key.
        /// nil and [] mean the same thing.
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

private struct PersistedLayoutV1: Codable {
    var dpad: PersistedLayout.DPad
    var buttons: [ButtonModel]
}

@MainActor
protocol ScreenEditSyncing {
    func endPreview()
    func resolvedPlacement(isPortrait: Bool) -> ScreenPlacement?
}

@MainActor
@Observable
class ControlsLayout {
    static let shared: ControlsLayout = {
        let layout = ControlsLayout()
        layout.screenSync = ScreenRegionApplierSync()
        return layout
    }()

    @ObservationIgnored var screenSync: ScreenEditSyncing?

    /// nil means that no game is active. Mutations then stay in memory.
    private(set) var currentGameID: String?

    private(set) var currentContainer: GameContainer?

    private(set) var activeManifest: ControlsManifest?

    private(set) var activeManifestSource: ControlsManifestLoader.ManifestLocation?

    private(set) var resolutionInvolvesDerivation = false

    private(set) var manifestRejection: ControlsRejection?

    private(set) var profileRejection: ControlsRejection?

    private(set) var provenance: LayoutProvenance = .builtin

    private(set) var pinFellThrough = false

    private(set) var importOfferPending = false

    private(set) var gameLayoutNoticePending = false

    private(set) var currentGameTitle: String?

    /// A snapshot from resolution time. A live recomputation can show
    /// metrics drift as a user edit, so auto-create compares with this.
    private var ambientBaseline: PersistedLayout?

    enum Role: Equatable {
        case player
        case profileEditor(name: String)
        case builtinViewer
    }

    private(set) var role: Role = .player

    var isEditorInstance: Bool { role != .player }

    var editorProfileName: String? {
        if case .profileEditor(let name) = role { return name }
        return nil
    }

    var metricsOverride: TouchZoneMetrics?

    var hasManifestTouchSection: Bool {
        activeManifest?.touch != nil
    }

    var resetConfirmationTitle: LocalizedStringResource {
        if case .pinnedProfile(let name) = provenance {
            return "Stop using \(name)?"
        }
        return hasManifestTouchSection ? "Reset to game default?" : "Reset to Empo default?"
    }

    var resetConfirmationActionTitle: LocalizedStringResource {
        if case .pinnedProfile = provenance {
            return "Stop using"
        }
        return "Reset"
    }

    /// This reads two files. Call it when the confirm alert shows,
    /// not on each render.
    func resetConfirmationMessage() -> LocalizedStringResource {
        if case .pinnedProfile(let name) = provenance {
            return screenChangesOnReset()
                ? "This game stops using the profile \(name). The profile keeps its layout. The screen returns to automatic placement."
                : "This game stops using the profile \(name). The profile keeps its layout."
        }
        return screenChangesOnReset()
            ? "This deletes your custom layout and returns the screen to automatic placement. You can't undo this."
            : "This deletes your custom layout. You can't undo this."
    }

    private func screenChangesOnReset() -> Bool {
        let isPortrait = currentOrientation == .portrait
        let current = effectiveScreenPlacement(
            stored: screenSync?.resolvedPlacement(isPortrait: isPortrait))
        guard current != nil else { return false }

        let store = LayoutProfilesManager.store
        var postResetPin: LayoutPin = .followChain
        if case .pinnedProfile = provenance {
            postResetPin = .followChain
        } else if let container = currentContainer {
            postResetPin = store.loadPin(forGameFolder: container.url).pin
        }
        let postReset = ScreenResolution.resolve(
            pin: postResetPin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { store.readScreen($0) })
        return (isPortrait ? postReset.portrait : postReset.landscape).placement == nil
    }

    private var separationLogSignature: String?

    private(set) var currentOrientation: ControlsOrientation = .portrait

    // MARK: - Oriented control state

    struct OrientedControls: Equatable {
        var dpadRelativeCenter: CGPoint
        var dpadSize: CGFloat = ControlsLayout.defaultDPadSize
        var dpadOpacity: Double = 1.0
        var dpadStyle: MovementStyle = .dpad
        var buttons: [ButtonModel]
        var actionButtons: [ActionButtonModel] = []
    }

    private var active = OrientedControls(
        dpadRelativeCenter: ControlsLayout.defaultDPadCenter(.portrait), buttons: [])
    private var inactive = OrientedControls(
        dpadRelativeCenter: ControlsLayout.defaultDPadCenter(.landscape),
        buttons: ControlsLayout.defaultButtons(.landscape))

    var dpadRelativeCenter: CGPoint {
        get { active.dpadRelativeCenter }
        set { active.dpadRelativeCenter = newValue }
    }
    var dpadSize: CGFloat {
        get { active.dpadSize }
        set {
            active.dpadSize =
                gridSnapActive ? Self.gridSnappedDPadSize(newValue) : newValue
        }
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

    /// The add UI checks this against the loader's cap. Thus a saved
    /// layout cannot fail V015 on its next load.
    var combinedButtonCount: Int { buttons.count + actionButtons.count }

    // MARK: - Edit-session undo (in-memory only, never persisted)

    private static let maxEditUndoDepth = 50

    private var editUndoStack: [OrientedControls] = []
    private(set) var editSessionActive = false

    var canUndo: Bool { editSessionActive && !editUndoStack.isEmpty }

    private init() {
        applyDefaultsForCurrentOrientation()
        observeProfileNotifications()
    }

    init(editorForProfile name: String, metrics: TouchZoneMetrics) {
        role = .profileEditor(name: name)
        metricsOverride = metrics
        applyDefaultsForCurrentOrientation()
        observeProfileNotifications()
        reloadEditorProfile()
    }

    init(viewerForBuiltins metrics: TouchZoneMetrics) {
        role = .builtinViewer
        metricsOverride = metrics
        applyDefaultsForCurrentOrientation()
    }

    // Written once on the main actor at init, read in deinit (which is
    // nonisolated by definition).
    @ObservationIgnored private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

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

    private func handleProfileChange(_ note: Notification) {
        guard note.object as AnyObject? !== self else { return }
        guard let name = note.userInfo?[LayoutProfilesManager.profileNameKey] as? String else { return }
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
        guard note.userInfo?[LayoutProfilesManager.gameIDKey] as? String == currentGameID else { return }
        staggerGeneration += 1
        resolveChain(container: container)
    }

    func beginEditSession() {
        editUndoStack.removeAll()
        editSessionActive = true
    }

    func endEditSession() {
        editSessionActive = false
        // Always end the preview. A stuck preview freezes the applier
        // for the rest of the session. Done can arrive in the middle
        // of a drag, and the gizmo unmounts with edit mode, so its own
        // recovery does not run. The profile editor saves after it
        // ends its session, so its edits must stay.
        if !isEditorInstance {
            screenEdits.removeAll()
            activeScreenDrag = nil
            screenSync?.endPreview()
        }
        // Done keeps the snapped values. Only the restore record goes.
        gridSnapOriginals = [:]
        gridSnapDPadOriginals = [:]
        gridSnapActive = false
    }

    // MARK: - Grid snap state

    struct GridSnapOriginal {
        var size: CGFloat
        var relativeCenter: CGPoint
    }

    var gridSnapOriginals: [UUID: GridSnapOriginal] = [:]
    var gridSnapDPadOriginals: [ControlsOrientation: GridSnapOriginal] = [:]

    /// A reset clears the restore record but stays in grid mode.
    /// Thus this flag cannot come from an empty record.
    var gridSnapActive = false

    static func gridSnappedSize(_ value: CGFloat) -> CGFloat {
        (value / ControlsZone.editGridStep).rounded() * ControlsZone.editGridStep
    }

    /// The arms of the D-pad are thirds of its size, so only a size
    /// in steps of 3 grid steps puts the inner arm borders on the grid.
    static func gridSnappedDPadSize(_ value: CGFloat) -> CGFloat {
        let step = ControlsZone.editGridStep * 3
        return (value / step).rounded() * step
    }

    /// The user can rotate during the session. Thus the ID can be in
    /// either orientation slot.
    func restoreGridSnapOriginal(_ id: UUID, _ original: GridSnapOriginal) {
        func restore<Control: PlacedControl>(in controls: inout [Control]) {
            guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
            controls[index].size = original.size
            controls[index].relativeCenter = original.relativeCenter
        }
        restore(in: &buttons)
        restore(in: &actionButtons)
        restore(in: &inactive.buttons)
        restore(in: &inactive.actionButtons)
    }

    func revertGridSnap() {
        let buttonOriginals = gridSnapOriginals
        let dpadOriginals = gridSnapDPadOriginals
        gridSnapOriginals = [:]
        gridSnapDPadOriginals = [:]
        gridSnapActive = false

        for (id, original) in buttonOriginals {
            restoreGridSnapOriginal(id, original)
        }

        for (orientation, original) in dpadOriginals {
            if orientation == currentOrientation {
                dpadSize = original.size
                dpadRelativeCenter = original.relativeCenter
            } else {
                inactive.dpadSize = original.size
                inactive.dpadRelativeCenter = original.relativeCenter
            }
        }
    }

    // MARK: - Screen region editing

    enum ScreenEdit: Equatable {
        case set(ScreenPlacement)
        case resetToAuto

        var placement: ScreenPlacement? {
            if case .set(let placement) = self { return placement }
            return nil
        }
    }

    private var screenEdits: [ControlsOrientation: ScreenEdit] = [:]
    var screenEditsDirty: Bool { !screenEdits.isEmpty }

    var pendingScreenEdit: ScreenEdit? { screenEdits[currentOrientation] }

    private func editedPlacement(
        _ orientation: ControlsOrientation, fallback: ScreenPlacement?
    ) -> ScreenPlacement? {
        guard let edit = screenEdits[orientation] else { return fallback }
        return edit.placement
    }

    func effectiveScreenPlacement(stored: ScreenPlacement?) -> ScreenPlacement? {
        if let live = activeScreenDrag?.liveRegion { return .region(live) }
        return editedPlacement(currentOrientation, fallback: stored)
    }

    private struct ActiveScreenDrag {
        /// nil when the orientation already had an entry. Then only
        /// the explicit reset goes back to engine auto placement.
        var autoReference: ScreenRegion?
        var liveRegion: ScreenRegion?
    }

    private var activeScreenDrag: ActiveScreenDrag?

    var screenDragActive: Bool { activeScreenDrag != nil }

    func beginScreenDrag(autoReference: ScreenRegion?) {
        guard editSessionActive else { return }
        activeScreenDrag = ActiveScreenDrag(autoReference: autoReference)
    }

    func screenDragChanged(_ region: ScreenRegion) {
        activeScreenDrag?.liveRegion = region
    }

    func endScreenDrag(region: ScreenRegion?) {
        guard let drag = activeScreenDrag else { return }
        activeScreenDrag = nil
        if let region, let auto = drag.autoReference,
            abs(region.x - auto.x) < 0.01, abs(region.y - auto.y) < 0.01,
            abs(region.w - auto.w) < 0.01, abs(region.h - auto.h) < 0.01
        {
            // The orientation had no entry, so a snapped-back drag is
            // no change. A stored edit would make Done create a profile.
            screenEdits.removeValue(forKey: currentOrientation)
            return
        }
        screenEdits[currentOrientation] = region.map { .set(.region($0)) } ?? .resetToAuto
    }

    func recordScreenEdit(_ placement: ScreenPlacement) {
        guard editSessionActive else { return }
        screenEdits[currentOrientation] = .set(placement)
    }

    private func abandonScreenEdits() {
        guard !screenEdits.isEmpty || activeScreenDrag != nil else { return }
        screenEdits.removeAll()
        activeScreenDrag = nil
        screenSync?.endPreview()
    }

    /// A reset of a drag that was never saved is no change. It must
    /// not make Done create a profile.
    func resetScreenEdit() {
        guard editSessionActive else { return }
        activeScreenDrag = nil
        var targetName: String?
        if let editorProfileName {
            targetName = editorProfileName
        } else if case .pinnedProfile(let name) = provenance {
            targetName = name
        }
        let storedRead = targetName.flatMap { LayoutProfilesManager.store.readScreen($0) }
        let storedEntry = storedRead.flatMap {
            currentOrientation == .portrait ? $0.portrait : $0.landscape
        }
        if storedEntry != nil {
            screenEdits[currentOrientation] = .resetToAuto
        } else if targetName == nil,
            screenSync?.resolvedPlacement(isPortrait: currentOrientation == .portrait) != nil
        {
            // The region comes from the default profile, so there is
            // nothing to delete in place. Done then creates a pinned
            // profile with no screen entry, which is engine auto. If
            // this edit is dropped, the region of the default comes
            // back after Done.
            screenEdits[currentOrientation] = .resetToAuto
        } else {
            screenEdits.removeValue(forKey: currentOrientation)
        }
    }

    private func mergedScreenPlacements(
        profile name: String, store: LayoutProfileStore
    ) -> (portrait: ScreenPlacement?, landscape: ScreenPlacement?) {
        let disk = store.readScreen(name)
        return (
            editedPlacement(.portrait, fallback: disk?.portrait),
            editedPlacement(.landscape, fallback: disk?.landscape)
        )
    }

    private func clearEditUndoStack() {
        editUndoStack.removeAll()
    }

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

    func switchGame(id newGameID: String?, container: GameContainer?, title: String? = nil) {
        if currentGameID != nil {
            try? save()
        }
        // A failed save() can leave screen edits behind. They must
        // not leak into the next game's first save.
        endEditSession()
        clearEditUndoStack()
        staggerGeneration += 1
        currentGameID = newGameID
        currentContainer = container
        currentGameTitle = title
        profileRejection = nil
        pinFellThrough = false
        importOfferPending = false
        gameLayoutNoticePending = false
        separationLogSignature = nil
        activeManifestSource = nil
        resolutionInvolvesDerivation = false
        Self.activeKeys =
            container.flatMap { GameCores.core(forGameAt: $0.gameURL)?.defaultKeys(forGameAt: $0.gameURL) }
            ?? GameKey.standard
        loadManifest(from: container?.gameURL)
        if let container, newGameID != nil {
            Self.migrateLegacyPersistence(container: container)
            BindingStore.migrateRenamedActions(container: container)
            runProfileMigration(container: container)
            resolveChain(container: container)
            return
        }
        provenance = .builtin
        ambientBaseline = nil
        applyDefaultsForCurrentOrientation()
    }

    func setOrientation(_ new: ControlsOrientation) {
        guard new != currentOrientation else { return }

        // The drag rect uses the canvas of the old orientation. It
        // must not commit in the new orientation.
        if activeScreenDrag != nil {
            activeScreenDrag = nil
            screenSync?.endPreview()
        }

        clearEditUndoStack()
        staggerGeneration += 1

        swap(&active, &inactive)
        currentOrientation = new
    }

    /// Only game-shipped layouts depend on the metrics. Profiles and
    /// the builtin layout do not.
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

    nonisolated static let defaultDPadSize = CGFloat(ControlLimits.defaultDPadSize)

    nonisolated static func defaultDPadCenter(_ orientation: ControlsOrientation) -> CGPoint {
        let dpad = BuiltinLayout.dpad(isLandscape: orientation == .landscape)
        return CGPoint(x: dpad.x, y: dpad.y)
    }

    /// `switchGame` sets these before the layout resolves.
    nonisolated(unsafe) private static var activeKeys = GameKey.standard

    nonisolated static func defaultButtons(_ orientation: ControlsOrientation) -> [ButtonModel] {
        let centers = BuiltinLayout.buttonCenters(isLandscape: orientation == .landscape)
        return zip(activeKeys, centers).map { key, center in
            ButtonModel(
                label: key.label, scancode: key.scancode,
                relativeCenter: CGPoint(x: center.x, y: center.y),
                size: CGFloat(ControlLimits.defaultButtonSize))
        }
    }

    nonisolated static var builtinKeys: [BuiltinLayout.Key] {
        activeKeys.map { BuiltinLayout.Key(label: $0.label, code: KeyCodeTable.code(for: $0.scancode)) }
    }

    // MARK: - Reset

    /// A pinned game unpins, and the profile keeps its contents. Thus
    /// a reset cannot change the other games that use the profile.
    func resetToResolvedDefault() {
        guard !isEditorInstance else { return }
        recordEditSnapshot()

        // The unpin below re-resolves the screen through the
        // pin-change observer of the applier.
        abandonScreenEdits()

        // A revert after the reset would put the pre-snap values back
        // over the reset.
        gridSnapOriginals = [:]
        gridSnapDPadOriginals = [:]
        gridSnapActive = false

        if case .pinnedProfile = provenance, let container = currentContainer {
            do {
                try LayoutProfilesManager.writePin(.followChain, for: container, from: self)
            } catch {
                NSLog("layout pin: unpin failed for \(container.id): \(error)")
            }
            pinFellThrough = false
            profileRejection = nil
            provenance = ambientProvenance()
            // Undo restores the layout but not the pin, so the next
            // commit would create a fork. Thus undo stops at this reset.
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

    private static func defaultControls(
        for orientation: ControlsOrientation
    ) -> OrientedControls {
        OrientedControls(
            dpadRelativeCenter: defaultDPadCenter(orientation),
            buttons: defaultButtons(orientation))
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

    // MARK: - Edit-drag collision

    /// In window space.
    var editChromeFrames: [CGRect] = []

    /// In window space.
    var toolbarKeepout: CGRect = .null

    var editGeometry: EditGeometry?

    /// The clamp band insets by padding plus innerPadding on each
    /// side. With the padding alone, the d-pad was 12 pt short and
    /// overflowed the border.
    var requiredEditZoneHeight: CGFloat {
        let tallestButton =
            (buttons.map(\.size) + actionButtons.map(\.size)).max() ?? 0
        return max(dpadSize, tallestButton)
            + 2 * (ControlsZone.padding + ControlsZone.innerPadding)
            + ControlsZone.toolbarGap
    }

    func screenDragAllowedRect(
        isPortrait: Bool, overlayOn: Bool, canvasSize: CGSize, safeArea: EdgeInsets
    ) -> CGRect {
        let safeBottom =
            isPortrait ? canvasSize.height - safeArea.bottom : canvasSize.height
        let maxBottom =
            isPortrait && !overlayOn
            ? safeBottom - requiredEditZoneHeight
            : safeBottom
        let top = isPortrait ? safeArea.top : 0
        return CGRect(
            x: safeArea.leading,
            y: top,
            width: canvasSize.width - safeArea.leading - safeArea.trailing,
            height: maxBottom - top)
    }

    /// When overlay turns off, a deep region must move above the fit
    /// limit. If not, the zone has no space and the controls stack at
    /// the bottom.
    func overlayToggledRegion(
        from region: ScreenRegion, isPortrait: Bool, canvasSize: CGSize,
        safeArea: EdgeInsets
    ) -> ScreenRegion {
        var toggled = region
        toggled.overlay = !region.overlay
        guard !toggled.overlay, isPortrait, canvasSize.height > 0 else { return toggled }
        let allowed = screenDragAllowedRect(
            isPortrait: isPortrait, overlayOn: false, canvasSize: canvasSize,
            safeArea: safeArea)
        let limit = Double(allowed.maxY / canvasSize.height)
        let top = Double(allowed.minY / canvasSize.height)
        if toggled.y + toggled.h > limit {
            toggled.y = max(top, limit - toggled.h)
            toggled.h = min(toggled.h, limit - toggled.y)
        }
        return toggled
    }

    private func dragObstacles(
        draggedID: UUID?, draggedIsDPad: Bool, geoSize: CGSize,
        safeArea: EdgeInsets, controlsMinY: CGFloat
    ) -> [EditDragSolver.Circle] {
        var obstacles: [EditDragSolver.Circle] = []
        func append(_ relativeCenter: CGPoint, _ size: CGFloat) {
            let absolute = ControlsZone.absolutePosition(
                for: relativeCenter, in: geoSize,
                controlSize: CGSize(width: size, height: size),
                safeArea: safeArea, controlsMinY: controlsMinY, keepout: toolbarKeepout)
            obstacles.append(
                EditDragSolver.Circle(
                    x: Double(absolute.x), y: Double(absolute.y),
                    radius: Double(size) / 2))
        }
        for button in buttons where button.id != draggedID {
            append(button.relativeCenter, button.size)
        }
        for button in actionButtons where button.id != draggedID {
            append(button.relativeCenter, button.size)
        }
        if !draggedIsDPad {
            append(dpadRelativeCenter, dpadSize)
        }
        return obstacles
    }

    private var chromeWalls: [EditDragSolver.Rect] {
        (editChromeFrames + [toolbarKeepout].filter { !$0.isNull }).map {
            EditDragSolver.Rect(
                x: Double($0.minX), y: Double($0.minY),
                width: Double($0.width), height: Double($0.height))
        }
    }

    /// The clamp and the push-out can fight at the zone edges. Thus
    /// the drag rejects an update that still collides after the solve.
    func dragPositionCollides(
        _ center: CGPoint, draggedID: UUID?, draggedIsDPad: Bool,
        controlSize: CGFloat, geoSize: CGSize, safeArea: EdgeInsets,
        controlsMinY: CGFloat
    ) -> Bool {
        EditDragSolver.collides(
            x: Double(center.x), y: Double(center.y),
            radius: Double(controlSize) / 2,
            obstacles: dragObstacles(
                draggedID: draggedID, draggedIsDPad: draggedIsDPad, geoSize: geoSize,
                safeArea: safeArea, controlsMinY: controlsMinY),
            walls: chromeWalls)
    }

    /// `previous` is the side memory of the drag.
    func collisionResolvedCenter(
        _ desired: CGPoint, previous: CGPoint?, draggedID: UUID?, draggedIsDPad: Bool,
        controlSize: CGFloat, geoSize: CGSize, safeArea: EdgeInsets,
        controlsMinY: CGFloat
    ) -> CGPoint {
        let resolved = EditDragSolver.resolvedCenter(
            desiredX: Double(desired.x), desiredY: Double(desired.y),
            previousX: previous.map { Double($0.x) },
            previousY: previous.map { Double($0.y) },
            radius: Double(controlSize) / 2,
            obstacles: dragObstacles(
                draggedID: draggedID, draggedIsDPad: draggedIsDPad, geoSize: geoSize,
                safeArea: safeArea, controlsMinY: controlsMinY),
            walls: chromeWalls)
        return CGPoint(x: resolved.x, y: resolved.y)
    }

    // MARK: - Display-time button separation

    /// Separation runs after the clamp transform. A separation before
    /// it misses the overlaps that the clamp brings back. With
    /// `separate: false`, edit mode renders raw, so a drag does not
    /// push its neighbors.
    func separatedDisplayPositions(
        for geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat,
        separate: Bool = true,
        includeActionButton: (ActionButtonModel) -> Bool = { _ in true }
    ) -> [UUID: CGPoint] {
        // Hidden action buttons (unavailable during play) must not
        // take part, or an invisible button pushes visible ones away.
        let visibleActionButtons = actionButtons.filter(includeActionButton)
        guard buttons.count + visibleActionButtons.count > 0, geoSize.width > 0,
            geoSize.height > 0
        else { return [:] }

        let allCircles: [(id: UUID, center: CGPoint, size: CGFloat)] =
            buttons.map { ($0.id, $0.relativeCenter, $0.size) }
            + visibleActionButtons.map { ($0.id, $0.relativeCenter, $0.size) }

        let inputs = allCircles.map { circle -> (x: Double, y: Double, size: Double) in
            let clamped = ControlsZone.absolutePosition(
                for: circle.center, in: geoSize,
                controlSize: CGSize(width: circle.size, height: circle.size),
                safeArea: safeArea, controlsMinY: controlsMinY, keepout: toolbarKeepout
            )
            return (x: Double(clamped.x), y: Double(clamped.y), size: Double(circle.size))
        }

        if !separate {
            var centers: [UUID: CGPoint] = [:]
            for (index, circle) in allCircles.enumerated() {
                centers[circle.id] = CGPoint(
                    x: CGFloat(inputs[index].x), y: CGFloat(inputs[index].y))
            }
            return centers
        }

        let dpadClamped = ControlsZone.absolutePosition(
            for: dpadRelativeCenter, in: geoSize,
            controlSize: CGSize(width: dpadSize, height: dpadSize),
            safeArea: safeArea, controlsMinY: controlsMinY, keepout: toolbarKeepout
        )

        // Separate inside the clamp band, not the full window. Against
        // the window box, a crushed zone pushed controls past its
        // borders.
        let pad = ControlsZone.padding + ControlsZone.innerPadding
        let bandMinX = Double(safeArea.leading + pad)
        let bandMinY = Double(max(safeArea.top + pad, controlsMinY + pad))
        let bandWidth = max(
            1, Double(geoSize.width - safeArea.trailing - pad) - bandMinX)
        let bandHeight = max(
            1, Double(geoSize.height - safeArea.bottom - pad) - bandMinY)

        let bandInputs = inputs.map { input in
            (x: input.x - bandMinX, y: input.y - bandMinY, size: input.size)
        }
        let obstacles = [
            (
                x: Double(dpadClamped.x) - bandMinX,
                y: Double(dpadClamped.y) - bandMinY,
                size: Double(dpadSize)
            )
        ]

        let keepout = toolbarKeepout.insetBy(
            dx: -ControlsZone.innerPadding, dy: -ControlsZone.innerPadding)
        let walls =
            keepout.isNull
            ? []
            : [
                EditDragSolver.Rect(
                    x: Double(keepout.minX) - bandMinX, y: Double(keepout.minY) - bandMinY,
                    width: Double(keepout.width), height: Double(keepout.height))
            ]

        let result = ButtonSeparation.separate(
            bandInputs,
            width: bandWidth,
            height: bandHeight,
            obstacles: obstacles,
            walls: walls
        )

        if result.movedCount > 0 {
            let signature =
                "\(result.movedCount)-\(Int(geoSize.width))x\(Int(geoSize.height))-\(allCircles.count)"
            if separationLogSignature != signature, let container = currentContainer {
                separationLogSignature = signature
                container.appendLogLine(
                    "controls: separated \(result.movedCount) overlapping buttons",
                    fileName: UserControlsFile.logFileName
                )
            }
        }

        var centers: [UUID: CGPoint] = [:]
        // A region from another device or from the editor can give a
        // deep controlsMinY and collapse the band. Keep each center
        // above the safe bottom.
        let maxBottom = Double(geoSize.height - safeArea.bottom) - Double(pad)
        for (index, circle) in allCircles.enumerated() {
            let point = result.positions[index]
            let half = Double(circle.size) / 2
            centers[circle.id] = CGPoint(
                x: CGFloat(point.x + bandMinX),
                y: CGFloat(min(point.y + bandMinY, maxBottom - half)))
        }
        return centers
    }

    // MARK: - Persistence

    /// Never write the per-game `EmpoState/controls.json`. Its dead
    /// touch section must stay byte-identical (copy, not move).
    ///
    /// A failed write throws and keeps every unsaved edit, so a later
    /// save can write it.
    func save() throws {
        if isEditorInstance {
            try editorSave()
            return
        }
        guard let container = currentContainer, currentGameID != nil else { return }
        let store = LayoutProfilesManager.store

        switch provenance {
        case .pinnedProfile(let name):
            var changed = false
            var failure: Error?
            let section = materializedTouchSection()
            let controlsOnDisk = store.readProfile(name)?.touch.map { existing in
                ProfileMaterializer.canonicalBytes(
                    ProfileMaterializer.materialize(
                        user: existing, manifest: nil,
                        builtins: LayoutProfilesManager.builtins(), metrics: layoutMetrics()))
            }
            if controlsOnDisk != ControlsManifestSerializer.serialize(section) {
                do {
                    try store.writeProfile(name, touch: section)
                    changed = true
                } catch {
                    NSLog("layout profile: save of \(name) failed: \(error)")
                    failure = error
                }
            }
            if screenEditsDirty {
                let merged = mergedScreenPlacements(profile: name, store: store)
                let disk = store.readScreen(name)
                var screenSaved = true
                if merged.portrait != disk?.portrait || merged.landscape != disk?.landscape {
                    do {
                        try store.writeScreen(
                            name, portrait: merged.portrait, landscape: merged.landscape)
                        changed = true
                    } catch {
                        NSLog("layout profile: screen save of \(name) failed: \(error)")
                        failure = error
                        screenSaved = false
                    }
                }
                if screenSaved {
                    screenEdits.removeAll()
                    screenSync?.endPreview()
                }
            }
            if changed {
                LayoutProfilesManager.postProfileChange(name: name, from: self)
            }
            if let failure { throw failure }

        case .gameLayout, .defaultProfile, .builtin:
            // Only an edit-session commit can create a profile. A save
            // at crash teardown must not create one.
            guard editSessionActive else { return }
            guard let baseline = ambientBaseline else { return }
            let current = currentPersistedLayout()
            let layoutsChanged =
                !Self.layoutsEquivalent(current.portrait, baseline.portrait)
                || !Self.layoutsEquivalent(current.landscape, baseline.landscape)
            guard layoutsChanged || screenEditsDirty else { return }
            let base = currentGameTitle ?? container.url.lastPathComponent
            let name = store.uniqueName(base: base)
            do {
                try store.createProfile(name, touch: materializedTouchSection())
            } catch {
                NSLog("layout profile: create of \(name) failed: \(error)")
                throw error
            }
            // An orientation with no edit gets the resolved region.
            // The new pin is terminal. Without this copy, an edit of
            // only the controls under a default-profile region sets
            // the screen to automatic.
            let resolvedScreen = ScreenResolution.resolve(
                pin: store.loadPin(forGameFolder: container.url).pin,
                defaultProfileName: LayoutProfilesManager.defaultProfileName,
                readScreen: { store.readScreen($0) })
            let portrait = editedPlacement(
                .portrait, fallback: resolvedScreen.portrait.placement)
            let landscape = editedPlacement(
                .landscape, fallback: resolvedScreen.landscape.placement)
            var screenFailure: Error?
            if portrait != nil || landscape != nil {
                do {
                    try store.writeScreen(name, portrait: portrait, landscape: landscape)
                } catch {
                    NSLog("layout profile: screen save of \(name) failed: \(error)")
                    screenFailure = error
                }
            }
            do {
                try LayoutProfilesManager.writePin(.profile(name), for: container, from: self)
            } catch {
                // This session still saves to the new profile, so no
                // edit is lost. The next launch uses the old layout.
                NSLog("layout pin: pin to \(name) failed for \(container.id): \(error)")
            }
            provenance = .pinnedProfile(name)
            pinFellThrough = false
            LayoutProfilesManager.postProfileChange(name: name, from: self)
            if let screenFailure {
                // The next save takes the pinned path, which reads the
                // screen from the new profile. Keep the resolved
                // regions as edits so that it writes the same values.
                if let portrait { screenEdits[.portrait] = .set(portrait) }
                if let landscape { screenEdits[.landscape] = .set(landscape) }
                throw screenFailure
            }
            screenEdits.removeAll()
            screenSync?.endPreview()
        }
    }

    /// Never sparse. A sparse section resolves against the next game
    /// that pins the profile.
    func materializedTouchSection() -> TouchSection {
        let layout = currentPersistedLayout()
        return TouchSection(
            portrait: Self.touchLayout(from: layout.portrait),
            landscape: Self.touchLayout(from: layout.landscape)
        )
    }

    func editorSave() throws {
        guard let name = editorProfileName else { return }
        let store = LayoutProfilesManager.store
        defer { LayoutProfilesManager.postProfileChange(name: name, from: self) }
        do {
            try store.writeProfile(name, touch: materializedTouchSection())
            if screenEditsDirty {
                let merged = mergedScreenPlacements(profile: name, store: store)
                try store.writeScreen(name, portrait: merged.portrait, landscape: merged.landscape)
                screenEdits.removeAll()
            }
        } catch {
            NSLog("layout profile: editor save of \(name) failed: \(error)")
            throw error
        }
    }

    func reloadEditorProfile() {
        guard let name = editorProfileName,
            let touch = LayoutProfilesManager.store.readProfile(name)?.touch
        else { return }
        applyProfileSection(touch)
    }

    /// Call this after the store rename.
    func editorRenamed(to name: String) {
        guard case .profileEditor = role else { return }
        role = .profileEditor(name: name)
    }

    // MARK: - Chain resolution

    private func resolveChain(container: GameContainer) {
        let store = LayoutProfilesManager.store
        let loaded = store.loadPin(forGameFolder: container.url)
        if let note = loaded.note {
            container.appendLogLine(note, fileName: UserControlsFile.logFileName)
        }

        var pinnedRead: LayoutProfileStore.ProfileRead?
        if case .profile(let name) = loaded.pin {
            pinnedRead = store.readProfile(name)
            if let pinnedRead {
                store.logProblems(name, read: pinnedRead)
            }
        }

        let outcome = LayoutResolution.resolve(
            pin: loaded.pin,
            gameLayoutOccupied: activeManifest?.touch != nil,
            store: store,
            defaultProfileName: LayoutProfilesManager.defaultProfileName)

        pinFellThrough = outcome.fellThrough
        profileRejection = pinnedRead?.rejection

        provenance = outcome.provenance
        gameLayoutNoticePending = false
        switch outcome.provenance {
        case .pinnedProfile:
            if let touch = pinnedRead?.touch {
                applyProfileSection(touch)
            }
        case .gameLayout:
            gameLayoutNoticePending =
                loaded.pin == .followChain
                && LayoutProfilesManager.defaultProfileName != nil
                && currentGameID.map { !Self.shownGameLayoutNotices().contains($0) } == true
            applyResolvedLayout()
        case .defaultProfile(let name):
            if let touch = store.validTouch(name) {
                applyProfileSection(touch)
            }
        case .builtin:
            resolutionInvolvesDerivation = false
            applyDefaultsForCurrentOrientation()
        }

        ambientBaseline = ambientResolved()
    }

    /// Profile gaps complete against the builtin only. A game manifest
    /// would put values of one game into a portable profile.
    private func applyProfileSection(_ touch: TouchSection) {
        let metrics = layoutMetrics()
        let materialized = ProfileMaterializer.materialize(
            user: touch, manifest: nil,
            builtins: LayoutProfilesManager.builtins(), metrics: metrics)
        resolutionInvolvesDerivation = false
        applyV2(
            PersistedLayout(
                portrait: Self.oriented(
                    from: materialized.portrait, orientation: .portrait,
                    manifest: nil, metrics: metrics),
                landscape: Self.oriented(
                    from: materialized.landscape, orientation: .landscape,
                    manifest: nil, metrics: metrics)))
    }

    private func ambientProvenance() -> LayoutProvenance {
        LayoutResolution.resolve(
            pin: .followChain,
            gameLayoutOccupied: activeManifest?.touch != nil,
            store: LayoutProfilesManager.store,
            defaultProfileName: LayoutProfilesManager.defaultProfileName
        ).provenance
    }

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
            let touch = LayoutProfilesManager.store.validTouch(defaultName)
        {
            let materialized = ProfileMaterializer.materialize(
                user: touch, manifest: nil,
                builtins: LayoutProfilesManager.builtins(), metrics: metrics)
            return PersistedLayout(
                portrait: Self.oriented(
                    from: materialized.portrait, orientation: .portrait,
                    manifest: nil, metrics: metrics),
                landscape: Self.oriented(
                    from: materialized.landscape, orientation: .landscape,
                    manifest: nil, metrics: metrics)
            )
        }
        return PersistedLayout(
            portrait: Self.builtinOriented(.portrait),
            landscape: Self.builtinOriented(.landscape)
        )
    }

    private func layoutMetrics() -> TouchZoneMetrics {
        metricsOverride ?? Self.touchZoneMetricsForManifestLoad()
    }

    // MARK: - Profile migration

    private func runProfileMigration(container: GameContainer) {
        let store = LayoutProfilesManager.store
        let recordURL = Self.migrationRecordURL
        // An unreadable record must not read as empty, or every game
        // migrates again.
        guard var record = MigrationRecord.load(at: recordURL) else {
            NSLog("layout migration: \(recordURL.lastPathComponent) is unreadable, migration skipped")
            return
        }
        let builtins = LayoutProfilesManager.builtins()

        // An invalid per-game file stays on disk as it is.
        let userTouch = UserControlsFile.loadAndLog(in: container)?.manifest?.touch
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
                    guard let touch = store.validTouch(name) else { return nil }
                    return ProfileMaterializer.canonicalBytes(
                        ProfileMaterializer.materialize(
                            user: touch, manifest: nil, builtins: builtins,
                            metrics: .reference))
                },
                profileHasScreen: { name in
                    FileManager.default.fileExists(atPath: store.screenURL(name).path)
                }
            ),
            builtins: builtins,
            metrics: .reference
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
            guard
                createAndPinProfile(
                    userTouch: userTouch, baseName: baseName, hash: hash,
                    container: container, record: &record)
            else { return }
        case .pinToExisting(let profile, let renameToShared, let hash):
            var target = profile
            if renameToShared {
                let shared = store.uniqueName(
                    base: String(
                        localized: "Shared layout",
                        comment: "Name of a layout profile that Empo makes when several games share edits."))
                do {
                    try LayoutProfilesManager.renameProfile(from: profile, to: shared)
                    target = shared
                    record.renameProfile(from: profile, to: shared)
                    record.sharedProfiles.insert(shared)
                } catch {
                    NSLog("layout migration: rename of \(profile) failed: \(error)")
                }
            }
            do {
                try store.writePin(.profile(target), forGameFolder: container.url)
                record.games[container.id] = MigrationRecord.Entry(hash: hash, profile: target)
            } catch {
                NSLog("layout migration: pin to \(target) failed for \(container.id): \(error)")
            }
        }
        Self.saveMigrationRecord(record, to: recordURL)
    }

    private static func saveMigrationRecord(_ record: MigrationRecord, to url: URL) {
        do {
            try record.save(to: url)
        } catch {
            NSLog("layout migration: save of \(url.lastPathComponent) failed: \(error)")
        }
    }

    private static var migrationRecordURL: URL {
        LayoutProfilesManager.profilesRootURL
            .appendingPathComponent(MigrationRecord.fileName)
    }

    private func createAndPinProfile(
        userTouch: TouchSection?, baseName: String, hash: String?,
        container: GameContainer, record: inout MigrationRecord
    ) -> Bool {
        let store = LayoutProfilesManager.store
        let materialized = ProfileMaterializer.materialize(
            user: userTouch, manifest: activeManifest?.touch,
            builtins: LayoutProfilesManager.builtins(), metrics: .reference)
        let name = store.uniqueName(base: baseName)
        do {
            try store.createProfile(name, touch: materialized.section)
            try store.writePin(.profile(name), forGameFolder: container.url)
        } catch {
            NSLog("layout migration: profile \(name) for \(container.id) failed: \(error)")
            return false
        }
        record.games[container.id] = MigrationRecord.Entry(
            hash: hash ?? FNV1a.hash64(ProfileMaterializer.canonicalBytes(materialized)),
            profile: name)
        return true
    }

    func acceptImportOffer() {
        guard let container = currentContainer, importOfferPending else { return }
        importOfferPending = false
        guard let userTouch = UserControlsFile.loadAndLog(in: container)?.manifest?.touch
        else { return }

        let recordURL = Self.migrationRecordURL
        let loadedRecord = MigrationRecord.load(at: recordURL)
        var record = loadedRecord ?? MigrationRecord()
        guard
            createAndPinProfile(
                userTouch: userTouch,
                baseName: currentGameTitle ?? container.url.lastPathComponent,
                hash: nil, container: container, record: &record)
        else { return }
        if loadedRecord != nil {
            Self.saveMigrationRecord(record, to: recordURL)
        } else {
            NSLog("layout migration: \(recordURL.lastPathComponent) is unreadable, left as it is")
        }

        resolveChain(container: container)
    }

    func dismissImportOffer() {
        importOfferPending = false
    }

    private static let gameLayoutNoticeKey = DefaultsKey.layoutProfilesGameNoticeShown

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

    /// Ignores `ButtonModel.id`. resolveInitialLayout makes new UUIDs
    /// on each call, so the synthesized == shows each manifest layout
    /// as customized.
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
        // Always non-nil. At load, an omitted key means "inherit the
        // shipped action buttons". A user who deleted them all must
        // save an explicit [].
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
                size: CGFloat(spec.size ?? ControlLimits.defaultDPadSize),
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
                    size: CGFloat(spec.size ?? ControlLimits.defaultButtonSize),
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
            size: CGFloat(spec.size ?? ControlLimits.defaultButtonSize),
            opacity: spec.opacity ?? 1.0
        )
    }

    /// A backup run calls this before it stages `EmpoState/`. Thus a
    /// game that the player did not open since the update also moves
    /// its layout into the container.
    static func migrateLegacyPersistence(container: GameContainer) {
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

        let controller = BindingStore.decodeLegacyPerGameMap(gameID: container.id)

        guard touch != nil || controller != nil else { return }

        guard UserControlsFile.write(in: container, touch: touch, bindings: controller) else {
            return
        }

        UserDefaults.standard.removeObject(forKey: layoutKey)
        UserDefaults.standard.removeObject(forKey: mapKey)
    }

    private static func decodeLegacyLayout(data: Data) -> PersistedLayout? {
        if let v2 = try? JSONDecoder().decode(PersistedLayout.self, from: data) {
            return v2
        }

        if let v1 = try? JSONDecoder().decode(PersistedLayoutV1.self, from: data) {
            let portrait = PersistedLayout.Oriented(dpad: v1.dpad, buttons: v1.buttons)
            let landscape = PersistedLayout.Oriented(
                dpad: Self.builtinOriented(.landscape).dpad,
                buttons: Self.defaultButtons(.landscape)
            )
            return PersistedLayout(portrait: portrait, landscape: landscape)
        }

        return nil
    }

    /// At game select, the engine usually has no `gameRect` yet. Then
    /// the portrait top uses an estimate from the typical game aspect.
    private static func touchZoneMetricsForManifestLoad() -> TouchZoneMetrics {
        let bounds = AppWindow.currentScreenBounds
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
            portraitTop =
                Double(safeArea.top) + portraitWidth / GameAspect.typical + ControlsZone.toolbarGap
        }

        // Side insets for the sideways layout: the notch depth, which
        // the render clamp keeps clear on both edges. A sideways window
        // has the exact values. In an upright window the notch is
        // usually at the top, but the closed iPhone Duo puts its camera
        // and status bar on the right edge (top 0, trailing 84).
        let isLandscapeNow = bounds.width > bounds.height
        let landscapeLeading: Double
        let landscapeTrailing: Double
        if isLandscapeNow {
            landscapeLeading = Double(safeArea.leading)
            landscapeTrailing = Double(safeArea.trailing)
        } else {
            let notchDepth = Double(max(safeArea.top, safeArea.leading, safeArea.trailing))
            landscapeLeading = notchDepth
            landscapeTrailing = notchDepth
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
        manifestRejection = nil
        guard let gameRoot else { return }

        let metrics = Self.touchZoneMetricsForManifestLoad()

        guard let outcome = ControlsManifestLoader.load(gameRoot: gameRoot, metrics: metrics) else {
            return
        }

        activeManifestSource = outcome.result.location
        let logsContainer = GameContainer(url: gameRoot.deletingLastPathComponent())
        for line in outcome.logLines {
            logsContainer.appendLogLine(line, fileName: UserControlsFile.logFileName)
        }
        activeManifest = outcome.result.manifest
        manifestRejection = outcome.result.rejection
    }

    private func applyResolvedLayout() {
        let metrics = Self.touchZoneMetricsForManifestLoad()
        resolutionInvolvesDerivation = false
        if let touch = activeManifest?.touch {
            let completion = TouchSectionCompletion.complete(touch, metrics: metrics)
            resolutionInvolvesDerivation = completion.involvedDerivation
        }
        let portrait = Self.resolveInitialLayout(
            manifest: activeManifest, orientation: .portrait, metrics: metrics)
        let landscape = Self.resolveInitialLayout(
            manifest: activeManifest, orientation: .landscape, metrics: metrics)
        applyV2(PersistedLayout(portrait: portrait, landscape: landscape))
    }

    fileprivate static func resolveInitialLayout(
        manifest: ControlsManifest?,
        orientation: ControlsOrientation,
        metrics: TouchZoneMetrics
    ) -> PersistedLayout.Oriented {
        let builtin = builtinOriented(orientation)
        guard let touch = manifest?.touch else { return builtin }

        let completed = TouchSectionCompletion.complete(touch, metrics: metrics).section

        let touchLayout: TouchLayout?
        switch orientation {
        case .portrait:
            touchLayout = completed.portrait
        case .landscape:
            touchLayout = completed.landscape
        }

        guard let touchLayout else { return builtin }

        let dpad: PersistedLayout.DPad
        if let spec = touchLayout.dpad {
            dpad = PersistedLayout.DPad(
                rx: CGFloat(spec.x),
                ry: CGFloat(spec.y),
                size: CGFloat(spec.size ?? ControlLimits.defaultDPadSize),
                opacity: spec.opacity ?? 1.0,
                style: spec.style
            )
        } else {
            dpad = builtin.dpad
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
                    size: CGFloat(spec.size ?? ControlLimits.defaultButtonSize),
                    opacity: spec.opacity ?? 1.0
                )
            }
        } else {
            buttons = builtin.buttons
        }

        // A shipped action button must not show as a user edit in the
        // customization diff.
        let actionButtons = touchLayout.actionButtons.map { specs in
            specs.map(actionButtonModel(from:))
        }

        return PersistedLayout.Oriented(
            dpad: dpad, buttons: buttons, actionButtons: actionButtons)
    }

    private static func builtinOriented(_ orientation: ControlsOrientation) -> PersistedLayout.Oriented {
        let dpadCenter = defaultDPadCenter(orientation)
        return PersistedLayout.Oriented(
            dpad: .init(
                rx: dpadCenter.x,
                ry: dpadCenter.y,
                size: defaultDPadSize,
                opacity: 1.0,
                style: .dpad
            ),
            buttons: defaultButtons(orientation),
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
            relativeCenter: resolvedSpawnRelativeCenter(size: newControlSize),
            size: newControlSize)
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
            relativeCenter: resolvedSpawnRelativeCenter(size: newControlSize),
            size: newControlSize)
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
        if let size {
            actionButtons[index].size =
                gridSnapActive ? Self.gridSnappedSize(size) : size
        }
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
        if let size {
            buttons[index].size = gridSnapActive ? Self.gridSnappedSize(size) : size
        }
        if let relativeCenter { buttons[index].relativeCenter = relativeCenter }
        if let opacity { buttons[index].opacity = opacity }
    }
}
