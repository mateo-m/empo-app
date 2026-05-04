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
    /// Long-lived state for the debug overlay. Kept on `PlayerView`
    /// so the overlay can be transitioned in/out via `if visible`
    /// without losing its FPS graph, cached game title, or RGSS
    /// version across show/hide cycles.
    @State private var debugOverlayState = DebugOverlayState()
    /// Toolbar starts dimmed so it doesn't dominate attention when the
    /// player first loads. Any tap (on the toolbar, on the game area,
    /// etc.) restores it to full opacity via `resetToolbarIdleTimer()`.
    @State private var toolbarOpacity: Double = Alpha.toolbarDim
    @State private var toolbarIdleTask: Task<Void, Never>?
    @State private var showQuitConfirm = false
    @State private var cheatsEnabled = false

    @State private var resumeSnapshot: UIImage?
    @State private var snapshotOpacity: Double = 1
    @State private var controlsVisible: Bool = true

    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var editingButton: ButtonModel?
    @State private var editingDPad = false
    @State private var draggingDPad = false
    @State private var draggingButtonID: UUID?

    /// More-menu sheet (toolbar -> ellipsis button). Houses pause /
    /// cheats / fast-forward / debug-overlay / quit so the toolbar
    /// itself stays trimmed to keyboard / edit / hide / more.
    @State private var showMoreSheet = false
    /// Live fast-forward state. Mirrored into the engine via
    /// `mkxp_setFastForwardMultiplier` so the FPS limiter scales the
    /// frame pacing while the toggle is on. The actual multiplier
    /// comes from `fastForwardMultiplier` (per-game setting).
    @State private var fastForwardActive = false
    /// Per-game fast-forward multiplier loaded from GameSettings.
    /// nil = disabled (the toolbar sheet hides the row). Refreshed
    /// every time the Menu sheet opens, since the user can pause →
    /// library → edit Game Settings → resume and change this value
    /// mid-session.
    @State private var fastForwardMultiplier: Int?

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
            let controlsMinY = ControlsZone.toolbarBottomY(
                isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, btnSize: toolbarBtnSize,
                geoHeight: geo.size.height)

            ZStack {
                if editMode {
                    editZoneBackground(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geo.size)
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
                        .onTapGesture {
                            toggleKeyboard()
                        }
                }

                if !controlsHidden && controlsVisible {
                    PlayerControlsOverlay(
                        layout: layout,
                        geo: geo,
                        controlsMinY: controlsMinY,
                        editMode: editMode,
                        editingButton: $editingButton,
                        editingDPad: $editingDPad,
                        draggingDPad: $draggingDPad,
                        draggingButtonID: $draggingButtonID
                    )
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
                            fastForwardMultiplier: fastForwardMultiplier
                        ),
                        onResetIdleTimer: { resetToolbarIdleTimer() }
                    )
                    .opacity(editMode ? 0 : 1)
                    .allowsHitTesting(!editMode)

                    PlayerEditToolbar(
                        isPortrait: isPortrait,
                        gameRect: gameRect,
                        safeArea: safeArea,
                        geoSize: geo.size,
                        showAddSheet: $showAddSheet,
                        showResetConfirm: $showResetConfirm,
                        onDone: { toggleEditMode() }
                    )
                    .opacity(editMode ? 1 : 0)
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
                        geoHeight: geo.size.height
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
            }
            // Push device orientation into ControlsLayout so it can
            // swap active/inactive per-orientation snapshots.
            // `initial: true` ensures the layout knows the orientation
            // as soon as PlayerView appears, not just on rotation.
            .onChange(of: isPortrait, initial: true) { _, nowPortrait in
                layout.setOrientation(nowPortrait ? .portrait : .landscape)
            }
        }
        .ignoresSafeArea()
        .onReceive(
            NotificationCenter.default.publisher(for: NSNotification.Name(rawValue: "TCTextInputMode"))
        ) { note in
            // Engine fired SDL_StartTextInput / SDL_StopTextInput
            // because the game asked for text input via
            // `Input.text_input = true/false`. Auto-flip the
            // keyboard mode so the soft keyboard appears (or
            // dismisses) without user action.
            //
            // No-op if the user already has the keyboard open via
            // the toolbar toggle - the keyboardMode state is just
            // re-set to the same value.
            let active = (note.userInfo?["active"] as? Bool) ?? false
            if active != keyboardMode {
                keyboardMode = active
                if active {
                    AppWindow.setAllowKeyWindow(true)
                }
            }
        }
        .onAppear {
            TCInstallKeyEventWatcher()
            TCInstallTextInputModeWatcher()

            // Load the per-game fast-forward multiplier (and re-push
            // to the engine if the toggle was already on). Fires on
            // first launch AND on resume from pause -> library ->
            // resume, so the in-game state always tracks the latest
            // Game Settings value the user might have edited while
            // paused.
            syncFastForwardFromSettings()

            // Pick up the pause snapshot and hold it until the engine
            // signals its first frame. Hide controls during transition.
            //
            // The toolbar is deliberately NOT reset to full opacity on
            // first appear - it stays at its `toolbarOpacity` default
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
            Text("Are you sure you want to quit the current game?")
        }
        .sheet(isPresented: $showMoreSheet) {
            PlayerMoreSheet(
                gameTitle: appState.selectedGame?.title ?? "Game",
                showDebugOverlay: $showDebugOverlay,
                fastForwardActive: $fastForwardActive,
                fastForwardMultiplier: fastForwardMultiplier,
                onPause: { appState.requestPause() },
                onCheats: { toggleCheats() },
                onQuit: { showQuitConfirm = true }
            )
        }
        .onChange(of: showMoreSheet) { _, opened in
            // The user can pause -> library -> Game Settings ->
            // resume mid-session, so refresh the per-game multiplier
            // every time the Menu sheet opens. If they bumped fast
            // forward from 2x to 4x while paused, the toggle should
            // pick that up; if they disabled it entirely, the row
            // should disappear.
            guard opened else { return }
            syncFastForwardFromSettings()
        }
        .onChange(of: fastForwardActive) { _, active in
            // Active = use the per-game configured multiplier; not
            // active = 1 (no scaling). Engine clamps to >= 1.
            let mult = active ? (fastForwardMultiplier ?? 1) : 1
            mkxp_setFastForwardMultiplier(Int32(mult))
        }
        .tint(nil)
        .controlsEditDialogs(
            layout: layout,
            showAddSheet: $showAddSheet,
            showResetConfirm: $showResetConfirm,
            editingButton: $editingButton,
            editingDPad: $editingDPad
        )
    }

    /// Re-read the per-game fast-forward multiplier from disk and
    /// reconcile the UI toggle with the engine's actual state.
    /// Called on PlayerView appear (initial launch + resume) and
    /// whenever the Menu sheet opens.
    ///
    /// SwiftUI can recycle `PlayerView` when the user pauses to the
    /// library and resumes, which resets `@State fastForwardActive`
    /// back to its default `false`. The engine's host-bridge
    /// multiplier is process-static and survives that recycle, so
    /// the only reliable "is fast-forward currently on?" signal is
    /// the bridge itself - reading it here lets the toolbar toggle
    /// reflect the engine's truth instead of stale local state.
    ///
    /// Reconciliation rules (engine state vs. configured value):
    ///   - engine fast-forwarding AND settings still allow it ->
    ///     toggle on; .onChange pushes the configured value back to
    ///     the bridge so an in-pause settings edit (e.g. 4x -> 2x)
    ///     takes effect on resume.
    ///   - engine fast-forwarding BUT settings cleared the
    ///     multiplier -> toggle off; .onChange pushes 1 to the
    ///     bridge so the engine stops speeding next frame.
    ///   - engine at 1x -> toggle off regardless of settings.
    private func syncFastForwardFromSettings() {
        guard let container = appState.selectedGame?.container else { return }
        let s = GameSettings.load(from: container.empoStateURL)
        fastForwardMultiplier = s.speedMultiplier

        let engineMult = Int(mkxp_getFastForwardMultiplier())
        let configuredMult = s.speedMultiplier ?? 1
        let shouldBeActive = engineMult > 1 && configuredMult >= 2

        if fastForwardActive != shouldBeActive {
            // Setting fastForwardActive triggers `.onChange` which
            // writes the bridge to the right value (configured
            // multiplier when active, 1 when not), so we don't
            // call mkxp_setFastForwardMultiplier directly here.
            fastForwardActive = shouldBeActive
        }
    }

    @ViewBuilder
    private func editZoneBackground(controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize) -> some View
    {
        let bounds = ControlsZone.bounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
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
        withAnimation(Motion.snappy) {
            editMode.toggle()
        }
        if keyboardMode {
            toggleKeyboard()
        }
        if !editMode {
            layout.save()
            resetToolbarIdleTimer()
        }
    }

    private func toggleHideControls() {
        withAnimation(Motion.snappy) {
            controlsHidden.toggle()
        }
        resetToolbarIdleTimer()
    }

    private func toggleKeyboard() {
        keyboardMode.toggle()
        if !keyboardMode {
            AppWindow.setAllowKeyWindow(false)
        }
    }

    /// Toggle the JoiPlay-derived cheat menu. First tap arms $CHEATS
    /// and injects a HOME keypress so the in-game Scene_Cheat hook
    /// fires immediately; second tap disables $CHEATS again. The
    /// Ruby-side poller installed by the engine keeps $CHEATS in
    /// sync with the bridge flag each Input.update.
    private func toggleCheats() {
        cheatsEnabled.toggle()
        mkxp_setCheatsEnabled(cheatsEnabled)
        if cheatsEnabled {
            // Inject a synthetic HOME keypress. The Ruby side's
            // Input.trigger?(HOME) returns true only on the frame the
            // key transitions from released to pressed, so the KEYUP
            // must land at least one RGSS tick (~16ms @ 60fps) after
            // the KEYDOWN. Otherwise both events get consumed in the
            // same eventthread batch and Input.update never observes
            // the pressed-edge the Scene_Map hook is waiting for.
            mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_HOME), 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                mkxp_injectKeyEvent(Int32(MKXP_SCANCODE_HOME), 0)
            }
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
            // Tied to the fade completion instead of a wall-clock
            // asyncAfter so the snapshot unmounts exactly
            // when the user no longer sees it, even if the spring
            // duration changes.
            resumeSnapshot = nil
            pauseManager.pauseSnapshot = nil
            pauseManager.snapshotCanFade = false
        }
    }
}
