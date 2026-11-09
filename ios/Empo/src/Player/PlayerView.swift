// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct PlayerView: View {
    @Bindable var appState: AppState
    @Bindable var engineState: EngineState
    var layout: ControlsLayout
    @Environment(\.pauseManager) private var pauseManager
    @Environment(\.appSettings) private var settings
    private var editMode: Bool { layout.editSessionActive }
    @AppStorage(DefaultsKey.controlsEditSnapToGrid) private var snapToGrid = false
    @State private var controlsHidden = false
    @State private var keyboardMode = false
    @State private var showDebugOverlay = false
    /// Lives here so the overlay keeps its FPS graph, game title, and
    /// RGSS version when it hides and shows again.
    @State private var debugOverlayState = DebugOverlayState()
    @State private var toolbarOpacity: Double = Alpha.toolbarDim
    @State private var toolbarIdleTask: Task<Void, Never>?
    @State private var actions = PlayerActionRegistry()

    @State private var resumeSnapshot: UIImage?
    @State private var snapshotOpacity: Double = 1
    @State private var input = SessionInput()
    @State private var controlsVisible: Bool = true

    @State private var editDialog: ControlsEditDialog?

    @State private var showMoreSheet = false
    @State private var sheetAction: SheetAction?
    @State private var showControllerRemap = false
    @State private var showLayoutProfilePicker = false

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let gameRect = engineState.gameRect
            let safeArea = AppWindow.currentSafeArea
            let toolbarBtnSize = IconButtonSize.sm.points
            let activeScreenPlacement = layout.effectiveScreenPlacement(
                stored: ScreenRegionApplier.resolvedPlacement(isPortrait: isPortrait))
            let forcedOverlay = activeScreenPlacement?.overlay
            let controlsMinY = ControlsZone.toolbarBottomY(
                isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea,
                btnSize: toolbarBtnSize,
                geoHeight: geo.size.height, forcedOverlay: forcedOverlay)
            let toolbarPlacement = PlayerToolbar.placement(
                isPortrait: isPortrait, safeArea: safeArea, geoSize: geo.size)
            let controlsSafeArea = ControlsZone.controlsSafeArea(safeArea, toolbar: toolbarPlacement)
            let toolbarKeepout = ControlsZone.toolbarKeepout(toolbarPlacement, geoSize: geo.size)

            ZStack {
                if settings.showTouchZone, !gameRect.isEmpty {
                    // gameRect is in window points. The GeometryReader
                    // ignores the safe area, so its space is the window space.
                    GeometryReader { _ in
                        Rectangle()
                            .fill(Color.brand.opacity(0.08))
                            .overlay(
                                Rectangle()
                                    .strokeBorder(Color.brand.opacity(0.7), lineWidth: 2)
                            )
                            .frame(width: gameRect.width, height: gameRect.height)
                            .position(x: gameRect.midX, y: gameRect.midY)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                if editMode {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .chromeHitRegion("editMode")
                        .allowsHitTesting(false)

                    editZoneBackground(
                        controlsMinY: controlsMinY, safeArea: controlsSafeArea, geoSize: geo.size)
                    if let caption = editZoneCaptionText {
                        editZoneCaption(caption, safeArea: safeArea)
                    }

                    screenRegionGizmo(
                        geoSize: geo.size, isPortrait: isPortrait, gameRect: gameRect)
                }
                // Sits above the SDL game view, so a tap on the game
                // area closes the keyboard.
                if keyboardMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .chromeHitRegion("keyboardMode")
                        .onTapGesture {
                            toggleKeyboard()
                        }
                }

                if !controlsHidden && (controlsVisible || resumeSnapshot == nil) {
                    PlayerControlsOverlay(
                        layout: layout,
                        actions: actions,
                        geo: geo,
                        controlsMinY: controlsMinY,
                        editMode: editMode,
                        safeArea: controlsSafeArea,
                        editDialog: $editDialog
                    )
                }

                if editMode {
                    screenRegionChips(
                        geoSize: geo.size, isPortrait: isPortrait, gameRect: gameRect)
                }

                if controlsVisible {
                    PlayerToolbar(
                        isPortrait: isPortrait,
                        safeArea: safeArea,
                        geoSize: geo.size,
                        controlsHidden: controlsHidden,
                        keyboardShown: keyboardMode,
                        toolbarOpacity: toolbarOpacity,
                        onToggleKeyboard: { toggleKeyboard() },
                        onToggleEditMode: { toggleEditMode() },
                        onToggleHideControls: { toggleHideControls() },
                        onShowMore: { showMoreSheet = true },
                        onResetIdleTimer: { resetToolbarIdleTimer() }
                    )
                    .opacity(editMode ? 0 : 1)
                    .allowsHitTesting(!editMode)

                    PlayerEditToolbar(
                        controlsMinY: controlsMinY,
                        safeArea: controlsSafeArea,
                        geoSize: geo.size,
                        layout: layout,
                        editDialog: $editDialog,
                        onDone: { toggleEditMode() }
                    )
                    // Fade only. Hit testing stays on: a gesture that
                    // the system cancels can leave the drag flag set,
                    // and the buttons would then stop working.
                    .opacity(editMode ? (layout.screenDragActive ? 0.15 : 1) : 0)
                    .animation(.easeInOut(duration: 0.15), value: layout.screenDragActive)
                    .allowsHitTesting(editMode)
                }

                DraggableDebugOverlay(
                    state: debugOverlayState,
                    visible: showDebugOverlay,
                    isPortrait: isPortrait,
                    gameRect: gameRect,
                    safeArea: safeArea,
                    geoSize: geo.size,
                    useOverlayLayout: ControlsZone.useOverlayLayout(
                        isPortrait: isPortrait,
                        gameRect: gameRect,
                        safeArea: safeArea,
                        geoHeight: geo.size.height,
                        forcedOverlay: forcedOverlay
                    )
                )
                .allowsHitTesting(showDebugOverlay)
                .onChange(of: appState.selectedGame?.title, initial: true) { _, title in
                    // The RPG Maker XP, VX and VX Ace core reads the title
                    // from Game.ini and wins once it lands. The PSDK core reports no
                    // title, so the library name is all the overlay gets.
                    if !debugOverlayState.metadataLoaded, let title {
                        debugOverlayState.gameTitle = title
                    }
                }

                // Stays mounted in both keyboard states. Removing the
                // field while it is first responder kills the input
                // session mid-flight, and the orphaned keyboard window
                // flashes its own UI (a Memoji education splash) on
                // the way down. A mounted field resigns cleanly.
                KeyboardFieldRepresentable(
                    isActive: keyboardMode,
                    excludedScancodes: { accessoryExcludedScancodes },
                    onActivate: {
                        AppWindow.setAllowKeyWindow(true)
                    }
                )
                .frame(width: 0, height: 0)

                if let snapshot = resumeSnapshot {
                    PauseSnapshotOverlay(
                        snapshot: snapshot,
                        rect: gameRect,
                        opacity: snapshotOpacity
                    )
                }

                if layout.gameLayoutNoticePending && !editMode && !layout.importOfferPending {
                    noticeCapsule(hitRegionKey: "gameLayoutNotice", safeArea: safeArea) {
                        Text("This game's own control layout is now active.")
                            .font(.footnote)
                            .foregroundStyle(.white)
                        Button("Got it") {
                            layout.dismissGameLayoutNotice()
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.brand)
                    }
                }

                if layout.importOfferPending && !editMode {
                    noticeCapsule(hitRegionKey: "importOffer", safeArea: safeArea) {
                        Text("This game includes its own control layout.")
                            .font(.footnote)
                            .foregroundStyle(.white)
                        Button("Import as profile") {
                            layout.acceptImportOffer()
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.brand)
                        Button("Not now") {
                            layout.dismissImportOffer()
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onChange(of: isPortrait, initial: true) { _, nowPortrait in
                layout.setOrientation(nowPortrait ? .portrait : .landscape)
                // Rotation must send the region again. Until it
                // arrives, the engine draws automatic placement.
                // `endPreview()` sends the region from disk.
                if let pending = layout.pendingScreenEdit {
                    ScreenRegionApplier.preview(
                        pending.placement.flatMap {
                            ScreenRegionApplier.region(for: $0, isPortrait: nowPortrait)
                        },
                        isPortrait: nowPortrait)
                } else {
                    ScreenRegionApplier.endPreview()
                }
            }
            // `initial: true`: the engine usually publishes gameRect
            // before PlayerView appears. Without it, the one real value
            // is lost, and translated layouts keep their estimated bands.
            .onChange(of: engineState.gameRect, initial: true) { _, rect in
                layout.refreshForGameGeometryChange()
                ScreenRegionApplier.gameRectChanged(rect)
            }
            .onChange(of: toolbarKeepout, initial: true) { _, keepout in
                layout.toolbarKeepout = keepout
            }
            .onChange(of: editMode) { _, editing in
                // No undo on exit: `endEditSession()` drops the
                // restore record, so Done keeps the snap.
                guard editing, snapToGrid else { return }
                layout.applyGridSnap(
                    geoSize: geo.size,
                    safeArea: controlsSafeArea,
                    controlsMinY: controlsMinY)
            }
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .background(Color.clear)
        .onAppear {
            // The engine fires SDL_StartTextInput / SDL_StopTextInput
            // when the game toggles `Input.text_input`. Auto-flip
            // keyboard mode so the soft keyboard appears without user
            // action.
            EngineSessionCoordinator.shared.setTextInputModeHandler { active in
                // While the game takes text, the keyboard is a
                // keyboard: no binding stands between the player and
                // the letters they type.
                input.textInputActive = active
                if active != keyboardMode {
                    keyboardMode = active
                    if active {
                        AppWindow.setAllowKeyWindow(true)
                    }
                }
            }

            // The registry must be wired BEFORE controller input
            // starts: the first controller edge can dispatch an
            // action as soon as start() attaches handlers.
            actions.pauseMenu = { appState.togglePauseMenu() }
            actions.toggleTouchControls = { toggleHideControls() }
            actions.log = { line in
                layout.currentContainer?.appendLogLine(line, fileName: UserControlsFile.logFileName)
            }
            input.actionHandler = { id, pressed in
                actions.handle(id, pressed: pressed)
            }
            input.deviceLogHandler = { line in
                layout.currentContainer?.appendLogLine(
                    line, fileName: UserControlsFile.logFileName)
            }
            // Bind runtime state BEFORE controller input starts:
            // start() polls attached controllers synchronously, and a
            // button already held at resume must find the per-game
            // multiplier loaded or its press drops as "unavailable".
            // Fires on first launch AND on resume from pause ->
            // library -> resume (engine state is process-static).
            actions.runtime.bind(container: layout.currentContainer)
            applyBindings()
            input.start(overlayHidden: $controlsHidden, editMode: { layout.editSessionActive })

            // Pick up the pause snapshot and hold it until the engine
            // signals its first frame. Hide controls during transition.
            //
            // We deliberately do NOT reset the toolbar to full opacity
            // on first appear. It stays at its `toolbarOpacity` default
            // (0.3, dimmed) so it doesn't dominate attention when the
            // player first loads. Any user interaction starts the
            // normal restore-then-fade cycle.
            if let snapshot = pauseManager.pauseSnapshot {
                resumeSnapshot = snapshot
                snapshotOpacity = 1
                controlsVisible = false

                if pauseManager.snapshotCanFade {
                    startSnapshotFade()
                }
            }
        }
        .onDisappear {
            // A pause from edit mode removes this view. The next
            // player view starts outside edit mode, so the session
            // ends here, the same as Done.
            if editMode {
                layout.save()
                layout.endEditSession()
            }
            ChromeHitRegions.removeAll()
            input.stop()
            EngineSessionCoordinator.shared.clearTextInputModeHandler()
        }
        .onChange(of: layout.currentContainer) { _, container in
            applyBindings()
            actions.runtime.bind(container: container)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bindingsDidChange)) { _ in
            applyBindings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gameAreaTouchBegan)) { _ in
            resetToolbarIdleTimer()
        }
        .onChange(of: pauseManager.snapshotCanFade) { _, canFade in
            if canFade && resumeSnapshot != nil {
                startSnapshotFade()
            }
        }
        .sheet(isPresented: $showMoreSheet, onDismiss: runSheetAction) {
            PlayerMoreSheet(
                gameTitle: appState.selectedGame?.title,
                showDebugOverlay: $showDebugOverlay,
                fastForwardActive: Binding(
                    get: { actions.runtime.fastForwardActive },
                    set: { actions.runtime.setFastForward(active: $0) }
                ),
                fastForwardMultiplier: actions.runtime.fastForwardMultiplier,
                showControllerRemap: input.hasSeenPhysicalInput,
                onControllerRemap: { sheetAction = .controllerRemap },
                onLayoutProfile: { sheetAction = .layoutProfile },
                onPause: { sheetAction = .pause },
                onQuit: appState.canQuitGame ? { sheetAction = .quit } : nil,
                onCheats: actions.isAvailable(EmpoActionCatalog.toggleCheats)
                    ? { actions.handle(EmpoActionCatalog.toggleCheats, pressed: true) } : nil
            )
        }
        .sheet(isPresented: $showLayoutProfilePicker) {
            if let container = layout.currentContainer {
                LayoutProfilePickerSheet(container: container)
            }
        }
        .sheet(isPresented: $showControllerRemap) {
            BindingsView(
                container: layout.currentContainer,
                gameTitle: appState.selectedGame?.title,
                manifest: layout.activeManifest?.bindings,
                input: input,
                actions: actions
            )
        }
        .onChange(of: showMoreSheet) { _, opened in
            // The user can change the multiplier in Game Settings
            // during a pause. Read it again each time the sheet opens.
            guard opened else { return }
            actions.runtime.reconcile(container: layout.currentContainer)
        }
        .tint(nil)
        .controlsEditDialogs(
            layout: layout,
            actions: actions,
            dialog: $editDialog
        )
    }

    private struct ScreenGizmoContext {
        /// nil: the engine picks the placement.
        var effectivePlacement: ScreenPlacement?
        var effectiveRegion: ScreenRegion?
        var baseRect: CGRect
        var allowedRect: CGRect
        var autoRegion: ScreenRegion
        var overlayOn: Bool
    }

    private func screenGizmoContext(
        geoSize: CGSize, isPortrait: Bool, gameRect: CGRect
    ) -> ScreenGizmoContext {
        let resolved = ScreenRegionApplier.resolvedPlacement(isPortrait: isPortrait)
        let effectivePlacement = layout.effectiveScreenPlacement(stored: resolved)
        let effectiveRegion = effectivePlacement.flatMap {
            ScreenRegionApplier.region(for: $0, isPortrait: isPortrait)
        }
        // Clamp like the applier does. Stored fractions can fall
        // outside the safe area of this device.
        let baseRect: CGRect = {
            if let region = effectiveRegion {
                let clamped = ScreenRegionApplier.clampToSafeArea(region)
                return CGRect(
                    x: clamped.x * geoSize.width,
                    y: clamped.y * geoSize.height,
                    width: clamped.w * geoSize.width,
                    height: clamped.h * geoSize.height)
            }
            return gameRect.isEmpty
                ? CGRect(origin: .zero, size: geoSize)
                : gameRect
        }()
        return ScreenGizmoContext(
            effectivePlacement: effectivePlacement,
            effectiveRegion: effectiveRegion,
            baseRect: baseRect,
            allowedRect: layout.screenDragAllowedRect(
                isPortrait: isPortrait, overlayOn: effectivePlacement?.overlay ?? false,
                canvasSize: geoSize, safeArea: AppWindow.currentSafeArea),
            autoRegion: ScreenRegion(
                x: gameRect.minX / max(geoSize.width, 1),
                y: gameRect.minY / max(geoSize.height, 1),
                w: gameRect.width / max(geoSize.width, 1),
                h: gameRect.height / max(geoSize.height, 1)),
            overlayOn: effectivePlacement?.overlay ?? false)
    }

    @ViewBuilder
    private func screenRegionGizmo(
        geoSize: CGSize, isPortrait: Bool, gameRect: CGRect
    ) -> some View {
        let context = screenGizmoContext(
            geoSize: geoSize, isPortrait: isPortrait, gameRect: gameRect)
        GeometryReader { _ in
            ScreenRegionGizmo(
                canvasSize: geoSize,
                allowedRect: context.allowedRect,
                baseRect: context.baseRect,
                onDragBegan: {
                    // Snap-to-auto needs a live automatic rect. With a
                    // region active, the engine publishes the region rect.
                    layout.beginScreenDrag(
                        autoReference: context.effectivePlacement == nil && !gameRect.isEmpty
                            ? context.autoRegion : nil)
                },
                onDragChanged: { region in
                    layout.screenDragChanged(region)
                    ScreenRegionApplier.preview(region, isPortrait: isPortrait)
                },
                onDragEnded: { region in
                    layout.endScreenDrag(region: region)
                    if let pending = layout.pendingScreenEdit {
                        ScreenRegionApplier.preview(
                            pending.placement.flatMap {
                                ScreenRegionApplier.region(for: $0, isPortrait: isPortrait)
                            },
                            isPortrait: isPortrait)
                    } else {
                        // Nothing is pending, so leave preview mode.
                        // A stuck preview freezes the applier.
                        ScreenRegionApplier.endPreview()
                    }
                },
                overlayOn: context.overlayOn
            )
        }
        .ignoresSafeArea()
    }

    /// Drawn above the controls. In overlay mode, the controls cover
    /// the game area and would hide the chips.
    @ViewBuilder
    private func screenRegionChips(
        geoSize: CGSize, isPortrait: Bool, gameRect: CGRect
    ) -> some View {
        let context = screenGizmoContext(
            geoSize: geoSize, isPortrait: isPortrait, gameRect: gameRect)
        GeometryReader { _ in
            ScreenRegionChips(
                rect: context.baseRect,
                showsReset: context.effectivePlacement != nil,
                onReset: {
                    withAnimation(ScreenRegionGizmo.moveAnimation) {
                        layout.resetScreenEdit()
                    }
                    if let current = context.effectiveRegion,
                        let target = estimatedAutoRegion(
                            geoSize: geoSize, isPortrait: isPortrait,
                            aspect: gameRect.height > 0
                                ? gameRect.width / gameRect.height : GameAspect.typical)
                    {
                        ScreenRegionApplier.animateResetToAuto(
                            from: current, toEstimate: target, isPortrait: isPortrait)
                    } else {
                        ScreenRegionApplier.preview(nil, isPortrait: isPortrait)
                    }
                },
                overlayOn: context.overlayOn,
                onToggleOverlay: {
                    guard
                        let region = context.effectiveRegion
                            ?? (gameRect.isEmpty ? nil : context.autoRegion)
                    else { return }
                    let toggled = layout.overlayToggledRegion(
                        from: region, isPortrait: isPortrait, canvasSize: geoSize,
                        safeArea: AppWindow.currentSafeArea)
                    withAnimation(ScreenRegionGizmo.moveAnimation) {
                        layout.recordScreenEdit(.region(toggled))
                    }
                    ScreenRegionApplier.preview(toggled, isPortrait: isPortrait)
                }
            )
        }
        .ignoresSafeArea()
    }

    private func estimatedAutoRegion(
        geoSize: CGSize, isPortrait: Bool, aspect: CGFloat
    ) -> ScreenRegion? {
        let preset: ScreenPreset
        switch gamecore_getVerticalAlignment() {
        case GAMECORE_VALIGN_TOP: preset = .top
        case GAMECORE_VALIGN_CENTER: preset = .center
        default: preset = .topCenter
        }
        let safeArea = AppWindow.currentSafeArea
        return ScreenPresetPlacement.region(
            preset: preset,
            canvasWidth: Double(geoSize.width),
            canvasHeight: Double(geoSize.height),
            safeTop: Double(safeArea.top),
            safeBottom: Double(safeArea.bottom),
            safeLeading: Double(safeArea.leading),
            safeTrailing: Double(safeArea.trailing),
            isPortrait: isPortrait,
            aspect: Double(aspect))
    }

    private var editZoneCaptionText: LocalizedStringResource? {
        if layout.manifestRejectionErrorCount > 0 {
            return
                "This game's controls file has \(layout.manifestRejectionErrorCount) errors, so Empo used its own layout."
        }
        if layout.profileRejectionErrorCount > 0 {
            return
                "Your layout profile has \(layout.profileRejectionErrorCount) errors, so Empo used its own layout."
        }
        if layout.pinFellThrough {
            return "That layout profile is gone, so this game is using the Empo default."
        }
        return nil
    }

    private func editZoneCaption(_ text: LocalizedStringResource, safeArea: EdgeInsets) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, safeArea.bottom + Spacing.md)
            .allowsHitTesting(false)
    }

    /// Without a hit region, taps inside gameRect go to the engine,
    /// not to the buttons.
    private func noticeCapsule(
        hitRegionKey: String, safeArea: EdgeInsets,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack {
            Spacer()
            HStack(spacing: Spacing.lg) {
                content()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Color.black.opacity(Scrim.heavy))
            .clipShape(Capsule())
            .chromeHitRegion(hitRegionKey)
            .padding(.bottom, safeArea.bottom + Spacing.md)
        }
    }

    @ViewBuilder
    private func editZoneBackground(
        controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize
    )
        -> some View
    {
        let bounds = ControlsZone.bounds(
            controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let radii = ControlsZone.cornerRadii(safeArea: safeArea)

        UnevenRoundedRectangle(
            topLeadingRadius: radii.top,
            bottomLeadingRadius: radii.bottom,
            bottomTrailingRadius: radii.bottom,
            topTrailingRadius: radii.top
        )
        .strokeBorder(Color.white.opacity(Alpha.border), lineWidth: 1.5)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: radii.top,
                bottomLeadingRadius: radii.bottom,
                bottomTrailingRadius: radii.bottom,
                topTrailingRadius: radii.top
            )
            .fill(Color.black.opacity(Scrim.medium))
        )
        .frame(width: bounds.width, height: bounds.height)
        .position(x: bounds.midX, y: bounds.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private enum SheetAction {
        case pause, quit, controllerRemap, layoutProfile
    }

    private func applyBindings() {
        input.applyBindings(container: layout.currentContainer, manifest: layout.activeManifest?.bindings)
    }

    /// The pause and the quit remove this view. When they run while
    /// the More sheet is still on screen, SwiftUI can keep the view
    /// after the game ended. SwiftUI shows one sheet at a time, so the
    /// next sheet also waits until the More sheet is gone.
    private func runSheetAction() {
        let action = sheetAction
        sheetAction = nil
        switch action {
        case .pause: appState.requestPause()
        case .quit: appState.quitGame()
        case .controllerRemap: showControllerRemap = true
        case .layoutProfile: showLayoutProfilePicker = true
        case nil: break
        }
    }

    private func toggleEditMode() {
        let entering = !editMode
        if entering && controlsHidden {
            controlsHidden = false
            input.noteManualOverlayToggle()
        }
        if keyboardMode {
            toggleKeyboard()
        }
        if entering {
            withAnimation(Motion.snappy) {
                layout.beginEditSession()
            }
        } else {
            // Save before `endEditSession()`. The ambient auto-create
            // in `save()` runs only during an edit session.
            layout.save()
            withAnimation(Motion.snappy) {
                layout.endEditSession()
            }
            resetToolbarIdleTimer()
        }
    }

    private func toggleHideControls() {
        withAnimation(Motion.snappy) {
            controlsHidden.toggle()
        }
        input.noteManualOverlayToggle()
        resetToolbarIdleTimer()
    }

    private var accessoryExcludedScancodes: Set<Int32> {
        var covered = Set<Int32>()
        if !controlsHidden {
            covered.formUnion([
                Int32(GAMECORE_SCANCODE_UP), Int32(GAMECORE_SCANCODE_DOWN),
                Int32(GAMECORE_SCANCODE_LEFT), Int32(GAMECORE_SCANCODE_RIGHT),
            ])
            for button in layout.buttons {
                covered.insert(button.scancode)
            }
        }
        if input.controller.hasConnectedController {
            covered.formUnion(input.controller.boundKeyScancodes)
        }
        return covered
    }

    private func toggleKeyboard() {
        keyboardMode.toggle()
        // `KeyboardFieldRepresentable.updateUIView` gives the key
        // window back to SDL after the field resigns.
    }

    private func resetToolbarIdleTimer() {
        toolbarIdleTask?.cancel()
        if toolbarOpacity < 1 {
            withAnimation(Motion.snappy) {
                toolbarOpacity = 1.0
            }
        }
        toolbarIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Timing.toolbarIdleDelay))
            guard !Task.isCancelled else { return }
            if !editMode && !controlsHidden {
                withAnimation(Motion.slow) {
                    toolbarOpacity = Alpha.toolbarDim
                }
            }
        }
    }

    private func startSnapshotFade() {
        let fading = resumeSnapshot
        withAnimation(Motion.standard) {
            snapshotOpacity = 0
            controlsVisible = true
        } completion: {
            resumeSnapshot = nil
            // A pause during the fade gives a new snapshot, which
            // the next player view shows.
            guard let fading, pauseManager.pauseSnapshot === fading else { return }
            pauseManager.pauseSnapshot = nil
            pauseManager.snapshotCanFade = false
        }
    }
}
