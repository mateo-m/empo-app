import GameProbe
import SwiftUI

struct PlayerView: View {
    @Bindable var appState: AppState
    @Bindable var engineState: EngineState
    var layout: ControlsLayout
    @Environment(\.pauseManager) private var pauseManager
    @Environment(\.appSettings) private var settings
    @State private var editMode = false
    @State private var controlsHidden = false
    @State private var keyboardMode = false
    @State private var showDebugOverlay = false
    /// Long-lived state for the debug overlay. It lives on `PlayerView`
    /// so the overlay can transition in/out via `if visible`
    /// and keep its FPS graph, cached game title, and RGSS
    /// version across show/hide cycles.
    @State private var debugOverlayState = DebugOverlayState()
    /// Toolbar starts dimmed so it doesn't dominate attention when the
    /// player first loads. Any tap (on the toolbar, on the game area,
    /// etc.) restores it to full opacity via `resetToolbarIdleTimer()`.
    @State private var toolbarOpacity: Double = Alpha.toolbarDim
    @State private var toolbarIdleTask: Task<Void, Never>?
    @State private var showQuitConfirm = false
    /// Action dispatch + the runtime state actions act on (fast
    /// forward, cheats). Both input paths (touch function buttons,
    /// controller action bindings) route through this registry.
    @State private var actions = PlayerActionRegistry()

    @State private var resumeSnapshot: UIImage?
    @State private var snapshotOpacity: Double = 1
    @State private var controllerInput = ControllerInputManager()
    @State private var controlsVisible: Bool = true

    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var editingButton: ButtonModel?
    @State private var editingActionButton: ActionButtonModel?
    @State private var editingDPad = false
    @State private var draggingDPad = false
    @State private var draggingButtonID: UUID?

    /// More-menu sheet (toolbar -> ellipsis button). Houses pause /
    /// cheats / fast-forward / debug-overlay / quit so the toolbar
    /// itself stays trimmed to keyboard / edit / hide / more.
    @State private var showMoreSheet = false
    @State private var showControllerRemap = false
    @State private var showLayoutProfilePicker = false

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let gameRect = engineState.gameRect
            let safeArea = AppWindow.currentSafeArea
            // Toolbar sits at the top-right of the device in every
            // layout, so the portrait-specific size reduction (used when
            // the toolbar was cramped in the zone below the game) no
            // longer applies.
            let toolbarBtnSize = IconButtonSize.sm.points
            // An active screen region carries the profile's own
            // overlay choice; nil keeps the geometry heuristic.
            let activeScreenRegion =
                layout.pendingScreenEdit
                ?? ScreenRegionApplier.resolvedRegion(isPortrait: isPortrait)
            let forcedOverlay = activeScreenRegion?.overlay
            // The chrome follows the engine's republished gameRect
            // LIVE during a screen drag, so the controls zone tracks
            // the moving screen. The edit toolbar fades during the
            // drag instead of holding still.
            let controlsMinY = ControlsZone.toolbarBottomY(
                isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea,
                btnSize: toolbarBtnSize,
                geoHeight: geo.size.height, forcedOverlay: forcedOverlay)

            ZStack {
                // Debug visualization of the touch-mouse zone: the
                // exact rect AppWindow routes to the game view. Same
                // source (engine-published gameRect), so what you see
                // is literally what hitTest checks.
                if settings.showTouchZone, !gameRect.isEmpty {
                    // gameRect is in window points. The wrapping
                    // GeometryReader ignores the safe area so its
                    // local space matches window space exactly.
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

                    editZoneBackground(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geo.size)
                    if layout.manifestRejectionErrorCount > 0 {
                        let errorCount = layout.manifestRejectionErrorCount
                        let errorLabel = errorCount == 1 ? "error" : "errors"
                        Text(
                            "This game ships a controls.json with \(errorCount) \(errorLabel). See Logs."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, safeArea.bottom + Spacing.md)
                        .allowsHitTesting(false)
                    } else if layout.profileRejectionErrorCount > 0 {
                        let errorCount = layout.profileRejectionErrorCount
                        let errorLabel = errorCount == 1 ? "error" : "errors"
                        Text(
                            "The pinned profile has \(errorCount) \(errorLabel). See Logs."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, safeArea.bottom + Spacing.md)
                        .allowsHitTesting(false)
                    } else if layout.pinFellThrough {
                        Text(
                            "The pinned layout is missing. This game uses the next layout in line."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, safeArea.bottom + Spacing.md)
                        .allowsHitTesting(false)
                    }

                    screenRegionGizmo(
                        geoSize: geo.size, isPortrait: isPortrait, gameRect: gameRect)
                }
                // Invisible tap layer that dismisses the keyboard when
                // it's open. Placed below controls + toolbar so those
                // stay tappable, but above the SDL game view so any
                // tap on the game area folds the keyboard away.
                // Matches the standard iOS "tap outside to dismiss"
                // behavior for text fields.
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
                        safeArea: safeArea,
                        editingButton: $editingButton,
                        editingActionButton: $editingActionButton,
                        editingDPad: $editingDPad,
                        draggingDPad: $draggingDPad,
                        draggingButtonID: $draggingButtonID
                    )
                }

                // Chips copy ABOVE the controls: in overlay mode the
                // controls sit on the game area and would otherwise
                // bury the Screen / Reset / overlay chips.
                if editMode {
                    screenRegionGizmo(
                        geoSize: geo.size, isPortrait: isPortrait, gameRect: gameRect,
                        chipsOnly: true)
                }

                if controlsVisible {
                    PlayerToolbar(
                        isPortrait: isPortrait,
                        safeArea: safeArea,
                        geoSize: geo.size,
                        controlsHidden: controlsHidden,
                        toolbarOpacity: toolbarOpacity,
                        onToggleKeyboard: { toggleKeyboard() },
                        onToggleEditMode: { toggleEditMode() },
                        onToggleHideControls: { toggleHideControls() },
                        onShowMore: { showMoreSheet = true },
                        menuVisible: PlayerMoreSheet.hasContent(
                            settings: settings,
                            fastForwardMultiplier: actions.runtime.fastForwardMultiplier,
                            controllerRemapAvailable: controllerInput.hasHadControllerThisSession
                        ),
                        onResetIdleTimer: { resetToolbarIdleTimer() }
                    )
                    .opacity(editMode ? 0 : 1)
                    .allowsHitTesting(!editMode)

                    PlayerEditToolbar(
                        controlsMinY: controlsMinY,
                        safeArea: safeArea,
                        geoSize: geo.size,
                        layout: layout,
                        showAddSheet: $showAddSheet,
                        showResetConfirm: $showResetConfirm,
                        onDone: { toggleEditMode() }
                    )
                    // Fade while the screen gizmo drags, so the
                    // toolbar never hides the region or its handle
                    // mid-drag.
                    .opacity(editMode ? (layout.screenDragActive ? 0.15 : 1) : 0)
                    .animation(.easeInOut(duration: 0.15), value: layout.screenDragActive)
                    .allowsHitTesting(editMode && !layout.screenDragActive)
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

                if keyboardMode {
                    KeyboardFieldRepresentable(
                        isActive: keyboardMode,
                        onActivate: {
                            AppWindow.setAllowKeyWindow(true)
                        }
                    )
                    .frame(width: 0, height: 0)
                }

                // Fades out when the engine swaps its first post-resume frame
                if let snapshot = resumeSnapshot {
                    PauseSnapshotOverlay(
                        snapshot: snapshot,
                        rect: gameRect,
                        opacity: snapshotOpacity
                    )
                }

                // One-time heads-up: the game's own layout displaced
                // the user's default profile.
                if layout.gameLayoutNoticePending && !editMode && !layout.importOfferPending {
                    VStack {
                        Spacer()
                        HStack(spacing: Spacing.lg) {
                            Text("This game ships its own control layout; it is now active.")
                                .font(.footnote)
                                .foregroundStyle(.white)
                            Button("OK") {
                                layout.dismissGameLayoutNotice()
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.brand)
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.md)
                        .background(Color.black.opacity(Scrim.heavy))
                        .clipShape(Capsule())
                        // Without a hit region, taps inside gameRect
                        // route to the engine instead of the button.
                        .chromeHitRegion("gameLayoutNotice")
                        .padding(.bottom, safeArea.bottom + Spacing.md)
                    }
                }

                // A migrated-then-changed controls file in the game
                // folder waits for the user's import decision.
                if layout.importOfferPending && !editMode {
                    VStack {
                        Spacer()
                        HStack(spacing: Spacing.lg) {
                            Text("This game's folder has a controls file.")
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
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.md)
                        .background(Color.black.opacity(Scrim.heavy))
                        .clipShape(Capsule())
                        .chromeHitRegion("importOffer")
                        .padding(.bottom, safeArea.bottom + Spacing.md)
                    }
                }
            }
            // Push device orientation into ControlsLayout so it can
            // swap active/inactive per-orientation snapshots.
            // `initial: true` ensures the layout knows the orientation
            // as soon as PlayerView appears, not just on rotation.
            .onChange(of: isPortrait, initial: true) { _, nowPortrait in
                layout.setOrientation(nowPortrait ? .portrait : .landscape)
                // Rotation re-sends the region for the new
                // orientation; the engine draws automatic placement
                // until this call lands (orientation-tag guard).
                // Mid-edit-session, the new orientation's pending
                // edit outranks the resolved state; with nothing
                // pending, leaving preview mode re-applies from disk
                // in both the preview and the normal case.
                if let pending = layout.pendingScreenEdit {
                    ScreenRegionApplier.preview(pending, isPortrait: nowPortrait)
                } else {
                    ScreenRegionApplier.endPreview()
                }
            }
            // `initial: true`: the engine usually publishes gameRect
            // during the loading transition, BEFORE PlayerView mounts.
            // Without an initial firing we miss the one real publish,
            // and translated layouts keep their estimate-based bands.
            .onChange(of: engineState.gameRect, initial: true) { _, _ in
                layout.refreshForGameGeometryChange()
            }
        }
        .ignoresSafeArea()
        // Opt out of SwiftUI keyboard avoidance: the soft keyboard
        // must overlay the game/controls, never compress or shift
        // them. Distinct from `.ignoresSafeArea()` above, which only
        // covers the container regions.
        .ignoresSafeArea(.keyboard)
        .background(Color.clear)
        .onAppear {
            // The engine fires SDL_StartTextInput / SDL_StopTextInput
            // when the game toggles `Input.text_input`. Auto-flip
            // keyboard mode so the soft keyboard appears without user
            // action.
            EngineSessionCoordinator.shared.setTextInputModeHandler { active in
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
                layout.currentContainer?.appendLogLine(line, fileName: "controls.json.log")
            }
            controllerInput.actionHandler = { id, pressed in
                actions.handle(id, pressed: pressed)
            }
            // Bind runtime state BEFORE controller input starts:
            // start() polls attached controllers synchronously, and a
            // button already held at resume must find the per-game
            // multiplier loaded or its press drops as "unavailable".
            // Fires on first launch AND on resume from pause ->
            // library -> resume (engine state is process-static).
            actions.runtime.bind(container: layout.currentContainer)
            ControllerMapBindings.applyRuntimeMap(
                to: controllerInput, container: layout.currentContainer)
            controllerInput.start(overlayHidden: $controlsHidden, editMode: $editMode)

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
            ChromeHitRegions.removeAll()
            controllerInput.stop()
            EngineSessionCoordinator.shared.clearTextInputModeHandler()
        }
        .onChange(of: layout.currentContainer) { _, container in
            ControllerMapBindings.applyRuntimeMap(to: controllerInput, container: container)
            actions.runtime.bind(container: container)
        }
        .onReceive(NotificationCenter.default.publisher(for: .controllerMapDidChange)) { _ in
            ControllerMapBindings.applyRuntimeMap(
                to: controllerInput, container: layout.currentContainer)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gameAreaTouchBegan)) { _ in
            resetToolbarIdleTimer()
        }
        .onChange(of: pauseManager.snapshotCanFade) { _, canFade in
            if canFade && resumeSnapshot != nil {
                startSnapshotFade()
            }
        }
        .alert("Return to Library", isPresented: $showQuitConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) {
                appState.returnToLibrary()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("Do you want to quit the current game?")
        }
        .sheet(isPresented: $showMoreSheet) {
            PlayerMoreSheet(
                gameTitle: appState.selectedGame?.title ?? "Game",
                showDebugOverlay: $showDebugOverlay,
                fastForwardActive: Binding(
                    get: { actions.runtime.fastForwardActive },
                    set: { actions.runtime.setFastForward(active: $0) }
                ),
                fastForwardMultiplier: actions.runtime.fastForwardMultiplier,
                showControllerRemap: controllerInput.hasHadControllerThisSession,
                onControllerRemap: { showControllerRemap = true },
                onLayoutProfile: { showLayoutProfilePicker = true },
                onPause: { appState.requestPause() },
                onCheats: { actions.handle(EmpoActionCatalog.toggleCheats, pressed: true) },
                onQuit: { showQuitConfirm = true }
            )
        }
        .sheet(isPresented: $showLayoutProfilePicker) {
            if let container = layout.currentContainer {
                LayoutProfilePickerSheet(container: container)
            }
        }
        .sheet(isPresented: $showControllerRemap) {
            ControllerRemapView(
                container: layout.currentContainer,
                gameTitle: appState.selectedGame?.title ?? "Game",
                manifest: layout.activeManifest?.controller,
                controllerInput: controllerInput
            )
        }
        .onChange(of: showMoreSheet) { _, opened in
            // The user can pause -> library -> Game Settings ->
            // resume mid-session, so refresh the per-game multiplier
            // every time the Menu sheet opens. If they bumped fast
            // forward from 2x to 4x while paused, the toggle should
            // pick that up. If they turned it off entirely, the row
            // should disappear.
            guard opened else { return }
            actions.runtime.reconcile()
        }
        .tint(nil)
        .controlsEditDialogs(
            layout: layout,
            showAddSheet: $showAddSheet,
            showResetConfirm: $showResetConfirm,
            editingButton: $editingButton,
            editingActionButton: $editingActionButton,
            editingDPad: $editingDPad
        )
    }

    /// Edit-mode screen gizmo. Base rect precedence: this session's
    /// pending edit, then the resolved region, then the engine's
    /// automatic placement (the live gameRect). `chipsOnly` renders
    /// the second, above-the-controls copy that keeps the chips
    /// reachable in overlay mode.
    @ViewBuilder
    private func screenRegionGizmo(
        geoSize: CGSize, isPortrait: Bool, gameRect: CGRect, chipsOnly: Bool = false
    ) -> some View {
        let resolved = ScreenRegionApplier.resolvedRegion(isPortrait: isPortrait)
        let effective: ScreenRegion? = layout.pendingScreenEdit ?? resolved
        // The outline draws the CLAMPED region — the same rect the
        // applier sends — so it can never disagree with the picture
        // when stored fractions fall outside this device's safe
        // area.
        let baseRect: CGRect = {
            if let region = effective {
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
        // Same inset policy as the applier's clamp: landscape keeps
        // only the left/right insets. Without overlay mode, the
        // drag also blocks where the controls zone would drop below
        // the height its controls need — the profile opts into
        // overlay explicitly instead of squeezing the zone.
        let safeArea = AppWindow.currentSafeArea
        let overlayOn = (layout.pendingScreenEdit ?? resolved)?.overlay ?? false
        let safeBottom = isPortrait ? geoSize.height - safeArea.bottom : geoSize.height
        let maxBottom =
            isPortrait && !overlayOn
            ? safeBottom - ControlsZone.requiredEditZoneHeight
            : safeBottom
        let allowedRect = CGRect(
            x: safeArea.leading,
            y: isPortrait ? safeArea.top : 0,
            width: geoSize.width - safeArea.leading - safeArea.trailing,
            height: maxBottom - (isPortrait ? safeArea.top : 0))
        let autoRegion = ScreenRegion(
            x: gameRect.minX / max(geoSize.width, 1),
            y: gameRect.minY / max(geoSize.height, 1),
            w: gameRect.width / max(geoSize.width, 1),
            h: gameRect.height / max(geoSize.height, 1))

        GeometryReader { _ in
            ScreenRegionGizmo(
                canvasSize: geoSize,
                allowedRect: allowedRect,
                baseRect: baseRect,
                showsReset: effective != nil,
                onDragBegan: {
                    // Snap-to-auto only when the orientation had no
                    // entry: with an entry active, the engine
                    // publishes region-derived rects and there is no
                    // live auto rect to compare against.
                    layout.beginScreenDrag(
                        autoReference: effective == nil && !gameRect.isEmpty
                            ? autoRegion : nil)
                },
                onDragChanged: { region in
                    ScreenRegionApplier.preview(region, isPortrait: isPortrait)
                },
                onDragEnded: { region in
                    layout.endScreenDrag(region: region)
                    if let pending = layout.pendingScreenEdit {
                        ScreenRegionApplier.preview(pending, isPortrait: isPortrait)
                    } else {
                        // Snapped back with no prior edit: nothing is
                        // pending, so leave preview mode — a stuck
                        // preview would freeze the applier.
                        ScreenRegionApplier.endPreview()
                    }
                },
                onReset: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        layout.resetScreenEdit()
                    }
                    if let current = effective,
                        let target = estimatedAutoRegion(
                            geoSize: geoSize, isPortrait: isPortrait,
                            aspect: gameRect.height > 0
                                ? gameRect.width / gameRect.height : 4.0 / 3.0)
                    {
                        ScreenRegionApplier.animateResetToAuto(
                            from: current, toEstimate: target, isPortrait: isPortrait)
                    } else {
                        ScreenRegionApplier.preview(nil, isPortrait: isPortrait)
                    }
                },
                overlayOn: overlayOn,
                onToggleOverlay: {
                    guard var region = effective ?? (gameRect.isEmpty ? nil : autoRegion)
                    else { return }
                    region.overlay = !overlayOn
                    // Turning overlay OFF while the region sits deep
                    // must make room again: clamp the region back
                    // above the below-game limit (shift up, then
                    // shrink), or the zone reappears with no space
                    // and the controls stack at the bottom.
                    if !region.overlay, isPortrait, geoSize.height > 0 {
                        let safeBottom = geoSize.height - AppWindow.currentSafeArea.bottom
                        let limit = Double(
                            (safeBottom - ControlsZone.requiredEditZoneHeight)
                                / geoSize.height)
                        let top = Double(AppWindow.currentSafeArea.top / geoSize.height)
                        if region.y + region.h > limit {
                            region.y = max(top, limit - region.h)
                            region.h = min(region.h, limit - region.y)
                        }
                    }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        layout.recordScreenEdit(region)
                    }
                    ScreenRegionApplier.preview(region, isPortrait: isPortrait)
                },
                chipsOnly: chipsOnly,
                showsChips: chipsOnly
            )
        }
        .ignoresSafeArea()
    }

    /// Where the engine's automatic placement will land, in window
    /// fractions — the reset animation's target. Mirrors the fit in
    /// `recalculateScreenSize`: aspect-fit inside the safe-area
    /// container, vertical alignment in portrait, centered in
    /// landscape (top/bottom insets ignored there).
    private func estimatedAutoRegion(
        geoSize: CGSize, isPortrait: Bool, aspect: CGFloat
    ) -> ScreenRegion? {
        guard geoSize.width > 0, geoSize.height > 0, aspect > 0 else { return nil }
        let safeArea = AppWindow.currentSafeArea
        let availW = geoSize.width - safeArea.leading - safeArea.trailing
        let availH =
            isPortrait ? geoSize.height - safeArea.top - safeArea.bottom : geoSize.height
        guard availW > 1, availH > 1 else { return nil }

        var width = availW
        var height = width / aspect
        if height > availH {
            height = availH
            width = height * aspect
        }
        let x = safeArea.leading + (availW - width) / 2

        let y: CGFloat
        if isPortrait {
            let topY = safeArea.top
            let centerY = safeArea.top + (availH - height) / 2
            switch mkxp_getVerticalAlignment() {
            case MKXP_VALIGN_TOP: y = topY
            case MKXP_VALIGN_CENTER: y = centerY
            default: y = (topY + centerY) / 2
            }
        } else {
            y = (availH - height) / 2
        }
        return ScreenRegion(
            x: x / geoSize.width, y: y / geoSize.height,
            w: width / geoSize.width, h: height / geoSize.height)
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

    private func toggleEditMode() {
        let entering = !editMode
        if entering && controlsHidden {
            controlsHidden = false
            controllerInput.noteManualOverlayToggle()
        }
        withAnimation(Motion.snappy) {
            editMode.toggle()
        }
        if keyboardMode {
            toggleKeyboard()
        }
        if editMode {
            layout.beginEditSession()
        } else {
            // Save BEFORE ending the session: the ambient auto-create
            // branch only fires inside an edit session, and sheet-only
            // edits commit exactly here.
            layout.save()
            layout.endEditSession()
            resetToolbarIdleTimer()
        }
    }

    private func toggleHideControls() {
        withAnimation(Motion.snappy) {
            controlsHidden.toggle()
        }
        controllerInput.noteManualOverlayToggle()
        resetToolbarIdleTimer()
    }

    private func toggleKeyboard() {
        keyboardMode.toggle()
        if !keyboardMode {
            AppWindow.setAllowKeyWindow(false)
        }
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
        // Deliberately do NOT reset the toolbar idle timer here. The
        // toolbar should stay dimmed when the game first becomes
        // playable - users don't need the buttons screaming for
        // attention the moment the snapshot lifts. They'll brighten
        // in as soon as the user taps anywhere.
        withAnimation(Motion.standard) {
            snapshotOpacity = 0
            controlsVisible = true
        } completion: {
            // We tie this to the fade completion instead of a
            // wall-clock asyncAfter so the snapshot unmounts exactly
            // when the user no longer sees it, even if the spring
            // duration changes.
            resumeSnapshot = nil
            pauseManager.pauseSnapshot = nil
            pauseManager.snapshotCanFade = false
        }
    }
}
