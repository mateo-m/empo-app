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

struct ButtonModel: PlacedControl, Equatable {
    let id: UUID
    var label: String
    var scancode: Int32
    var relativeCenter: CGPoint
    var size: CGFloat
    var opacity: Double

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
}

struct ActionButtonModel: PlacedControl, Equatable {
    let id: UUID
    var action: String
    var relativeCenter: CGPoint
    var size: CGFloat
    var opacity: Double

    init(action: String, relativeCenter: CGPoint, size: CGFloat, opacity: Double = 1.0) {
        self.id = UUID()
        self.action = action
        self.relativeCenter = relativeCenter
        self.size = size
        self.opacity = opacity
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

/// The layout that older versions kept in UserDefaults. Only the
/// migration to the controls file reads it.
private struct LegacyLayout: Decodable {
    struct DPad: Decodable {
        var rx: CGFloat
        var ry: CGFloat
        var size: CGFloat
        var opacity: Double?
    }
    struct Oriented: Decodable {
        var dpad: DPad
        var buttons: [LegacyButton]
    }
    var portrait: Oriented
    var landscape: Oriented
}

private struct LegacyLayoutV1: Decodable {
    var dpad: LegacyLayout.DPad
    var buttons: [LegacyButton]
}

private struct LegacyButton: Decodable {
    var label = ""
    var scancode: Int32 = 0
    var rx: CGFloat = 0.5
    var ry: CGFloat = 0.5
    var size = CGFloat(ControlLimits.defaultButtonSize)
    var opacity = 1.0

    enum CodingKeys: String, CodingKey {
        case label, scancode, rx, ry, size, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? label
        scancode = try c.decodeIfPresent(Int32.self, forKey: .scancode) ?? scancode
        rx = try c.decodeIfPresent(CGFloat.self, forKey: .rx) ?? rx
        ry = try c.decodeIfPresent(CGFloat.self, forKey: .ry) ?? ry
        size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? size
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
    }
}

@MainActor
@Observable
class ControlsLayout {
    static let shared = ControlsLayout()

    /// The editor instances never begin a session, so their applier
    /// sends nothing.
    let screenRegion = ScreenRegionApplier()

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
    private var ambientBaseline: TouchSection?

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

    /// True when a reset sends the screen back to automatic placement.
    /// This reads two files, so do not call it on each render.
    func screenChangesOnReset() -> Bool {
        let isPortrait = currentOrientation == .portrait
        let current = effectiveScreenPlacement(
            stored: screenRegion.resolvedPlacement(isPortrait: isPortrait))
        guard current != nil else { return false }

        let store = LayoutProfilesManager.store
        let postResetPin: LayoutPin
        switch (provenance, currentContainer) {
        case (.pinnedProfile, _), (_, nil):
            postResetPin = .followChain
        case (_, let container?):
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
        var dpadSize = CGFloat(ControlLimits.defaultDPadSize)
        var dpadOpacity: Double = 1.0
        var dpadStyle: MovementStyle = .dpad
        var buttons: [ButtonModel]
        var actionButtons: [ActionButtonModel] = []
    }

    /// Each init replaces these with the builtin layout.
    private var active = OrientedControls(dpadRelativeCenter: .zero, buttons: [])
    private var inactive = OrientedControls(dpadRelativeCenter: .zero, buttons: [])

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
        applyBuiltinLayout()
        observeProfileNotifications()
    }

    init(editorForProfile name: String, metrics: TouchZoneMetrics, keys: [GameKey]) {
        role = .profileEditor(name: name)
        metricsOverride = metrics
        gameKeys = keys
        applyBuiltinLayout()
        observeProfileNotifications()
        reloadEditorProfile()
    }

    init(viewerForBuiltins metrics: TouchZoneMetrics, keys: [GameKey]) {
        role = .builtinViewer
        metricsOverride = metrics
        gameKeys = keys
        applyBuiltinLayout()
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
            resolveChain(container: container)
        default:
            break
        }
    }

    private func handlePinChange(_ note: Notification) {
        guard note.object as AnyObject? !== self, !isEditorInstance else { return }
        guard !editSessionActive, let container = currentContainer else { return }
        guard note.userInfo?[LayoutProfilesManager.gameIDKey] as? String == currentGameID else { return }
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
            activeScreenDrag = nil
            dropScreenEdits()
        }
        // Done keeps the snapped values. Only the restore record goes.
        dropGridSnapRecord()
    }

    // MARK: - Grid snap state

    var gridSnapOriginals: [UUID: GridSnapOriginal] = [:]
    var gridSnapDPadOriginals: [ControlsOrientation: GridSnapOriginal] = [:]

    /// The size mutators read this flag, so a size from a sheet also
    /// goes on the grid while snap is on.
    var gridSnapActive = false

    /// The user can rotate during the session. Thus the ID can be in
    /// either orientation slot.
    func setPlacement(of id: UUID, size: CGFloat, relativeCenter: CGPoint) {
        func set<Control: PlacedControl>(in controls: inout [Control]) {
            guard let index = controls.firstIndex(where: { $0.id == id }) else { return }
            controls[index].size = size
            controls[index].relativeCenter = relativeCenter
        }
        set(in: &buttons)
        set(in: &actionButtons)
        set(in: &inactive.buttons)
        set(in: &inactive.actionButtons)
    }

    func setDPadPlacement(in orientation: ControlsOrientation, size: CGFloat, relativeCenter: CGPoint) {
        if orientation == currentOrientation {
            dpadSize = size
            dpadRelativeCenter = relativeCenter
        } else {
            inactive.dpadSize = size
            inactive.dpadRelativeCenter = relativeCenter
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
        activeScreenDrag = nil
        dropScreenEdits()
    }

    /// The applier then shows the region on disk again.
    private func dropScreenEdits() {
        screenEdits.removeAll()
        screenRegion.endPreview()
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
            screenRegion.resolvedPlacement(isPortrait: currentOrientation == .portrait) != nil
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
        withAnimation(Motion.standard) {
            replaceControls(active: snapshot, inactive: inactive)
        }
    }

    /// `keys` are the keys of the game core, in grid order. The builtin
    /// layout puts one button on each.
    func switchGame(
        id newGameID: String?, container: GameContainer?, title: String? = nil,
        keys: [GameKey] = GameKey.standard
    ) {
        if currentGameID != nil {
            try? save()
        }
        // A failed save() can leave screen edits behind. They must
        // not leak into the next game's first save.
        endEditSession()
        clearEditUndoStack()
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
        gameKeys = keys
        loadManifest(container: container)
        if let container, newGameID != nil {
            Self.migrateLegacyPersistence(container: container, keys: keys)
            BindingStore.migrateRenamedActions(container: container)
            runProfileMigration(container: container)
            resolveChain(container: container)
            return
        }
        provenance = .builtin
        ambientBaseline = nil
        applyBuiltinLayout()
    }

    func setOrientation(_ new: ControlsOrientation) {
        guard new != currentOrientation else { return }

        // The drag rect uses the canvas of the old orientation. It
        // must not commit in the new orientation.
        if activeScreenDrag != nil {
            activeScreenDrag = nil
            screenRegion.endPreview()
        }

        clearEditUndoStack()
        replaceControls(active: inactive, inactive: active)
        currentOrientation = new
    }

    /// Only game-shipped layouts depend on the metrics. Profiles and
    /// the builtin layout do not.
    func refreshForGameGeometryChange() {
        guard let container = currentContainer, !isEditorInstance else { return }
        guard !editSessionActive else { return }
        guard provenance == .gameLayout else { return }

        separationLogSignature = nil
        loadManifest(container: container)
        resolveChain(container: container)
    }

    // MARK: - Builtin layout

    private(set) var gameKeys = GameKey.standard

    private var builtins: ProfileMaterializer.Builtins {
        LayoutProfilesManager.builtins(keys: gameKeys)
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
        dropGridSnapRecord()

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

        let resolved = controlsPair(ambientResolved())
        ambientBaseline = touchSection(active: resolved.active, inactive: resolved.inactive)
        inactive = resolved.inactive
        animateReset(to: resolved.active)
    }

    private func animateReset(to layout: OrientedControls) {
        let targetButtons = layout.buttons
        let targetActionButtons = layout.actionButtons
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
            dpadRelativeCenter = layout.dpadRelativeCenter
            dpadSize = layout.dpadSize
            dpadOpacity = layout.dpadOpacity
            dpadStyle = layout.dpadStyle
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

    /// The stagger tasks of a reset add their buttons only while this
    /// value stays the same.
    private var staggerGeneration = 0

    private func replaceControls(active: OrientedControls, inactive: OrientedControls) {
        staggerGeneration += 1
        self.active = active
        self.inactive = inactive
    }

    // MARK: - Edit geometry

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

    /// Upright and without overlay, the game screen stays above the
    /// controls zone.
    func screenDragAllowedRect(in canvas: ScreenCanvas, overlayOn: Bool) -> CGRect {
        var allowed = canvas.safeRect
        if canvas.isPortrait && !overlayOn {
            allowed.size.height -= requiredEditZoneHeight
        }
        return allowed
    }

    /// When overlay turns off, a deep region must move above the fit
    /// limit. If not, the zone has no space and the controls stack at
    /// the bottom.
    func overlayToggledRegion(from region: ScreenRegion, in canvas: ScreenCanvas) -> ScreenRegion {
        var toggled = region
        toggled.overlay = !region.overlay
        guard !toggled.overlay, canvas.isPortrait, canvas.size.height > 0 else { return toggled }
        let allowed = screenDragAllowedRect(in: canvas, overlayOn: false)
        let limit = Double(allowed.maxY / canvas.size.height)
        let top = Double(allowed.minY / canvas.size.height)
        if toggled.y + toggled.h > limit {
            toggled.y = max(top, limit - toggled.h)
            toggled.h = min(toggled.h, limit - toggled.y)
        }
        return toggled
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
                ProfileMaterializer.canonicalBytes(materialized(user: existing, manifest: nil))
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
                    dropScreenEdits()
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
            guard materializedTouchSection() != baseline || screenEditsDirty else { return }
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
                NSLog("layout pin: pin to \(name) failed for \(container.id): \(error)")
                // No game points to the profile without the pin. The
                // next save creates it again.
                try? store.deleteProfile(name)
                throw error
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
            dropScreenEdits()
        }
    }

    /// Never sparse. A sparse section resolves against the next game
    /// that pins the profile.
    func materializedTouchSection() -> TouchSection {
        touchSection(active: active, inactive: inactive)
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
                dropScreenEdits()
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
        var pinnedName: String?
        if case .profile(let name) = loaded.pin {
            pinnedName = name
            pinnedRead = store.readProfile(name)
            if let pinnedRead {
                store.logProblems(name, read: pinnedRead)
            }
        }
        if let name = LayoutProfilesManager.defaultProfileName, name != pinnedName,
            let read = store.readProfile(name)
        {
            store.logProblems(name, read: read)
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
            applyBuiltinLayout()
        }

        let ambient = controlsPair(ambientResolved())
        ambientBaseline = touchSection(active: ambient.active, inactive: ambient.inactive)
    }

    /// Profile gaps complete against the builtin only. A game manifest
    /// would put values of one game into a portable profile.
    private func applyProfileSection(_ touch: TouchSection) {
        resolutionInvolvesDerivation = false
        apply(materialized(user: touch, manifest: nil))
    }

    private func applyResolvedLayout() {
        let completion = activeManifest?.touch.map {
            TouchSectionCompletion.complete($0, metrics: layoutMetrics())
        }
        resolutionInvolvesDerivation = completion?.involvedDerivation ?? false
        apply(materialized(user: nil, manifest: completion?.section))
    }

    private func applyBuiltinLayout() {
        apply(materialized(user: nil, manifest: nil))
    }

    private func ambientProvenance() -> LayoutProvenance {
        LayoutResolution.resolve(
            pin: .followChain,
            gameLayoutOccupied: activeManifest?.touch != nil,
            store: LayoutProfilesManager.store,
            defaultProfileName: LayoutProfilesManager.defaultProfileName
        ).provenance
    }

    /// The layout of the chain without the pin of the game.
    private func ambientResolved() -> ProfileMaterializer.MaterializedTouch {
        if let manifest = activeManifest?.touch {
            return materialized(user: nil, manifest: manifest)
        }
        let defaultTouch = LayoutProfilesManager.defaultProfileName.flatMap {
            LayoutProfilesManager.store.validTouch($0)
        }
        return materialized(user: defaultTouch, manifest: nil)
    }

    private func materialized(
        user: TouchSection?, manifest: TouchSection?
    ) -> ProfileMaterializer.MaterializedTouch {
        ProfileMaterializer.materialize(
            user: user, manifest: manifest, builtins: builtins, metrics: layoutMetrics())
    }

    private func layoutMetrics() -> TouchZoneMetrics {
        metricsOverride ?? Self.touchZoneMetricsForManifestLoad()
    }

    // MARK: - Profile migration

    private func runProfileMigration(container: GameContainer) {
        let store = LayoutProfilesManager.store
        let recordURL = Self.migrationRecordURL
        var record = Self.loadMigrationRecord(at: recordURL)
        let builtins = builtins

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

    /// An unreadable record reads as empty, and the next save writes
    /// over it.
    private static func loadMigrationRecord(at url: URL) -> MigrationRecord {
        if let record = MigrationRecord.load(at: url) { return record }
        NSLog("layout migration: \(url.lastPathComponent) is unreadable, read as empty")
        return MigrationRecord()
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
            builtins: builtins, metrics: .reference)
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
        var record = Self.loadMigrationRecord(at: recordURL)
        guard
            createAndPinProfile(
                userTouch: userTouch,
                baseName: currentGameTitle ?? container.url.lastPathComponent,
                hash: nil, container: container, record: &record)
        else { return }
        Self.saveMigrationRecord(record, to: recordURL)

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

    // MARK: - Conversion

    private func controlsPair(
        _ layout: ProfileMaterializer.MaterializedTouch
    ) -> (active: OrientedControls, inactive: OrientedControls) {
        let portrait = Self.controls(from: layout.portrait, .portrait)
        let landscape = Self.controls(from: layout.landscape, .landscape)
        return currentOrientation == .portrait ? (portrait, landscape) : (landscape, portrait)
    }

    private func apply(_ layout: ProfileMaterializer.MaterializedTouch) {
        let pair = controlsPair(layout)
        replaceControls(active: pair.active, inactive: pair.inactive)
    }

    private func touchSection(active: OrientedControls, inactive: OrientedControls) -> TouchSection {
        let portrait = currentOrientation == .portrait ? active : inactive
        let landscape = currentOrientation == .portrait ? inactive : active
        return TouchSection(
            portrait: Self.touchLayout(from: portrait),
            landscape: Self.touchLayout(from: landscape))
    }

    /// The materializer fills each gap of the layout, so the fallbacks
    /// here only keep the types whole.
    private static func controls(
        from layout: TouchLayout, _ orientation: ControlsOrientation
    ) -> OrientedControls {
        let dpad = layout.dpad ?? BuiltinLayout.dpad(isLandscape: orientation == .landscape)
        return OrientedControls(
            dpadRelativeCenter: CGPoint(x: dpad.x, y: dpad.y),
            dpadSize: CGFloat(dpad.size ?? ControlLimits.defaultDPadSize),
            dpadOpacity: dpad.opacity ?? 1.0,
            dpadStyle: dpad.style,
            buttons: (layout.buttons ?? []).compactMap { spec in
                guard let scancode = KeyCodeTable.scancode(for: spec.key) else { return nil }
                return ButtonModel(
                    label: spec.label ?? KeyCodeTable.displayName(for: spec.key) ?? spec.key,
                    scancode: scancode,
                    relativeCenter: CGPoint(x: spec.x, y: spec.y),
                    size: CGFloat(spec.size ?? ControlLimits.defaultButtonSize),
                    opacity: spec.opacity ?? 1.0)
            },
            actionButtons: (layout.actionButtons ?? []).map { spec in
                ActionButtonModel(
                    action: spec.action,
                    relativeCenter: CGPoint(x: spec.x, y: spec.y),
                    size: CGFloat(spec.size ?? ControlLimits.defaultButtonSize),
                    opacity: spec.opacity ?? 1.0)
            })
    }

    /// The action buttons are never nil. At load, an omitted key means
    /// "inherit the shipped action buttons", so a user who deleted them
    /// all must save an explicit [].
    private static func touchLayout(from controls: OrientedControls) -> TouchLayout {
        TouchLayout(
            dpad: DPadSpec(
                x: Double(controls.dpadRelativeCenter.x),
                y: Double(controls.dpadRelativeCenter.y),
                size: Double(controls.dpadSize),
                opacity: controls.dpadOpacity,
                style: controls.dpadStyle),
            buttons: controls.buttons.compactMap { button in
                guard let key = KeyCodeTable.code(for: button.scancode) else { return nil }
                return ButtonSpec(
                    label: button.label.isEmpty ? nil : button.label,
                    key: key,
                    x: Double(button.relativeCenter.x),
                    y: Double(button.relativeCenter.y),
                    size: Double(button.size),
                    opacity: button.opacity)
            },
            actionButtons: controls.actionButtons.map { button in
                ActionButtonSpec(
                    action: button.action,
                    x: Double(button.relativeCenter.x),
                    y: Double(button.relativeCenter.y),
                    size: Double(button.size),
                    opacity: button.opacity)
            })
    }

    /// A backup run calls this before it stages `EmpoState/`. Thus a
    /// game that the player did not open since the update also moves
    /// its layout into the container.
    static func migrateLegacyPersistence(container: GameContainer, keys: [GameKey]) {
        guard !UserControlsFile.exists(in: container) else { return }

        let layoutKey = DefaultsKey.controlsLayout(gameID: container.id)
        let mapKey = DefaultsKey.controllerMap(gameID: container.id)
        let layoutData = UserDefaults.standard.data(forKey: layoutKey)
        let hasMap = UserDefaults.standard.data(forKey: mapKey) != nil
        guard layoutData != nil || hasMap else { return }

        let touch = layoutData.flatMap { legacyTouchSection(data: $0, keys: keys) }
        let controller = BindingStore.decodeLegacyPerGameMap(gameID: container.id)

        guard touch != nil || controller != nil else { return }

        guard UserControlsFile.write(in: container, touch: touch, bindings: controller) else {
            return
        }

        UserDefaults.standard.removeObject(forKey: layoutKey)
        UserDefaults.standard.removeObject(forKey: mapKey)
    }

    /// The legacy blob has no action buttons, so the section leaves the
    /// key out and the layout inherits the shipped ones.
    private static func legacyTouchSection(data: Data, keys: [GameKey]) -> TouchSection? {
        func layout(_ dpad: LegacyLayout.DPad, _ buttons: [LegacyButton]) -> TouchLayout {
            TouchLayout(
                dpad: DPadSpec(
                    x: Double(dpad.rx), y: Double(dpad.ry), size: Double(dpad.size),
                    opacity: dpad.opacity ?? 1.0),
                buttons: buttons.compactMap { button in
                    guard let key = KeyCodeTable.code(for: button.scancode) else {
                        NSLog(
                            "controls.json: Dropped button \"\(button.label)\" (scancode \(button.scancode) has no key name)"
                        )
                        return nil
                    }
                    return ButtonSpec(
                        label: button.label, key: key, x: Double(button.rx), y: Double(button.ry),
                        size: Double(button.size), opacity: button.opacity)
                })
        }
        if let v2 = try? JSONDecoder().decode(LegacyLayout.self, from: data) {
            return TouchSection(
                portrait: layout(v2.portrait.dpad, v2.portrait.buttons),
                landscape: layout(v2.landscape.dpad, v2.landscape.buttons))
        }
        if let v1 = try? JSONDecoder().decode(LegacyLayoutV1.self, from: data) {
            var landscape = LayoutProfilesManager.builtins(keys: keys).landscape
            landscape.actionButtons = nil
            return TouchSection(portrait: layout(v1.dpad, v1.buttons), landscape: landscape)
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
        let isLandscapeNow = ControlsOrientation.from(geoSize: bounds.size) == .landscape
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

    private func loadManifest(container: GameContainer?) {
        activeManifest = nil
        activeManifestSource = nil
        manifestRejection = nil
        guard let container,
            let outcome = ControlsManifestLoader.load(
                gameRoot: container.gameURL, metrics: layoutMetrics())
        else { return }

        activeManifestSource = outcome.result.location
        for line in outcome.logLines {
            container.appendLogLine(line, fileName: UserControlsFile.logFileName)
        }
        activeManifest = outcome.result.manifest
        manifestRejection = outcome.result.rejection
    }

    // MARK: - Mutators

    func addButton(label: String, scancode: Int32) {
        recordEditSnapshot()
        let button = ButtonModel(
            label: label, scancode: scancode,
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
