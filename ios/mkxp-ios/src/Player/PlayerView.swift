import SwiftUI

// MARK: - Constants

private let kToolbarIdleDelay: TimeInterval = 3.0

// MARK: - PlayerView

struct PlayerView: View {
    @Bindable var appState: AppState
    @Bindable var engineState: EngineState
    var layout: ControlsLayout
    var pauseManager = PauseManager.shared
    @State private var editMode = false
    @State private var controlsHidden = false
    @State private var keyboardMode = false
    @State private var showDebugOverlay = false
    @State private var toolbarOpacity: Double = 1.0
    @State private var toolbarIdleTask: Task<Void, Never>?
    @State private var showQuitConfirm = false

    // Resume snapshot — fades out to reveal live SDL
    @State private var resumeSnapshot: UIImage?
    @State private var snapshotOpacity: Double = 1
    @State private var controlsVisible: Bool = true

    // Edit mode trigger state
    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var editingButton: ButtonModel?
    @State private var showEditMenu = false

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let gameRect = engineState.gameRect
            let safeArea = geo.safeAreaInsets

            ZStack {
                // Transparent — passes touches through to SDL
                Color.clear
                    .allowsHitTesting(false)

                if !controlsHidden && controlsVisible {
                    // D-Pad
                    dpadView(in: geo)

                    // Action buttons
                    ForEach(layout.buttons) { button in
                        actionButtonView(button: button, in: geo)
                    }
                }

                // Toolbar (always visible unless editing)
                if controlsVisible {
                    if !editMode {
                        toolbarButtons(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
                    } else {
                        editToolbar(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
                    }
                }

                // Debug overlay
                if showDebugOverlay {
                    DebugOverlayView()
                        .frame(width: 220, height: 100)
                        .position(debugOverlayPosition(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea))
                }

                // Hidden keyboard field
                if keyboardMode {
                    KeyboardFieldRepresentable(
                        isActive: keyboardMode,
                        onActivate: {
                            AppWindow.setAllowKeyWindow(true)
                        }
                    )
                    .frame(width: 0, height: 0)
                }

                // Resume snapshot — positioned at gameRect, fades out when
                // the engine swaps its first post-resume frame.
                if let snapshot = resumeSnapshot {
                    Image(uiImage: snapshot)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: gameRect.width, height: gameRect.height)
                        .position(x: gameRect.midX, y: gameRect.midY)
                        .opacity(snapshotOpacity)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(true)
        }
        .ignoresSafeArea()
        .onAppear {
            TCInstallKeyEventWatcher()

            // Pick up the pause snapshot and hold it until the engine
            // signals its first frame. Hide controls during transition.
                if let snapshot = pauseManager.pauseSnapshot {
                resumeSnapshot = snapshot
                snapshotOpacity = 1
                controlsVisible = false

                if pauseManager.snapshotCanFade {
                    startSnapshotFade()
                }
            } else {
                resetToolbarIdleTimer()
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
        } message: {
            Text("Are you sure you want to quit the current game?")
        }
        .controlsEditDialogs(
            layout: layout,
            showAddSheet: $showAddSheet,
            showResetConfirm: $showResetConfirm,
            editingButton: $editingButton,
            showEditMenu: $showEditMenu
        )
    }

    // MARK: - D-Pad

    @ViewBuilder
    private func dpadView(in geo: GeometryProxy) -> some View {
        let size = layout.dpadSize
        let pos = absolutePosition(for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size), safeArea: geo.safeAreaInsets)

        DPadRepresentable(size: size, editing: editMode)
            .frame(width: size, height: size)
            .position(pos)
            .gesture(dpadDragGesture(in: geo), including: editMode ? .all : .none)
    }

    private func dpadDragGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let newCenter = value.location
                let clamped = clampToSafeArea(newCenter, controlSize: layout.dpadSize, in: geo)
                layout.dpadRelativeCenter = CGPoint(
                    x: clamped.x / geo.size.width,
                    y: clamped.y / geo.size.height
                )
            }
            .onEnded { _ in
                layout.save()
            }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtonView(button: ButtonModel, in geo: GeometryProxy) -> some View {
        let pos = absolutePosition(for: button.relativeCenter, in: geo.size, controlSize: CGSize(width: button.size, height: button.size), safeArea: geo.safeAreaInsets)

        ActionButtonRepresentable(
            label: button.label,
            scancode: button.scancode,
            buttonSize: button.size,
            editing: editMode
        )
        .frame(width: button.size, height: button.size)
        .position(pos)
        .gesture(buttonDragGesture(id: button.id, size: button.size, in: geo), including: editMode ? .all : .none)
        .simultaneousGesture(
            TapGesture().onEnded {
                editingButton = button
                showEditMenu = true
            },
            including: editMode ? .all : .none
        )
    }

    private func buttonDragGesture(id: UUID, size: CGFloat, in geo: GeometryProxy) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let newCenter = value.location
                let clamped = clampToSafeArea(newCenter, controlSize: size, in: geo)
                layout.updateButton(id: id, relativeCenter: CGPoint(
                    x: clamped.x / geo.size.width,
                    y: clamped.y / geo.size.height
                ))
            }
            .onEnded { _ in
                layout.save()
            }
    }

    // MARK: - Toolbar Buttons

    @ViewBuilder
    private func toolbarButtons(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize) -> some View {
        let btnSize = isPortrait && gameRect.height > 0 ? AppSize.toolbarButton - 8 : AppSize.toolbarButton
        let iconPt: CGFloat = isPortrait && gameRect.height > 0 ? 13 : 16
        let gap: CGFloat = isPortrait ? Spacing.sm : Spacing.md

        let buttons: [(icon: String, label: String, action: () -> Void, tint: Color)] = {
            var list: [(icon: String, label: String, action: () -> Void, tint: Color)] = []
            if AppSettings.shared.isEnabled(.gamePause) {
                list.append(("pause.fill", "Pause game", { pauseManager.requestPause() }, .white.opacity(0.8)))
            }
            list.append(("keyboard", "Toggle keyboard", { toggleKeyboard() }, .white.opacity(0.8)))
            if AppSettings.shared.debugMode {
                list.append(("chart.line.uptrend.xyaxis", "Debug overlay", { showDebugOverlay.toggle() }, .white.opacity(0.8)))
            }
            list.append(contentsOf: [
                ("gearshape.fill", "Edit controls", { toggleEditMode() }, .white.opacity(0.8)),
                (controlsHidden ? "eye.slash.fill" : "eye.fill", controlsHidden ? "Show controls" : "Hide controls", { toggleHideControls() }, .white.opacity(0.8)),
            ])
            if AppSettings.shared.isEnabled(.gameQuit) {
                list.append(("xmark.circle.fill", "Quit game", { showQuitConfirm = true }, .destructive))
            }
            return list
        }()

        let toolbarPosition = toolbarOrigin(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geoSize, btnSize: btnSize, gap: gap, count: CGFloat(buttons.count))

        HStack(spacing: gap) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, entry in
                Button(action: {
                    resetToolbarIdleTimer()
                    entry.action()
                }) {
                    Image(systemName: entry.icon)
                        .font(.system(size: iconPt, weight: .medium))
                        .foregroundStyle(entry.tint)
                        .frame(width: btnSize, height: btnSize)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .accessibilityLabel(entry.label)
            }
        }
        .opacity(toolbarOpacity)
        .position(toolbarPosition)
    }

    // MARK: - Edit Toolbar

    @ViewBuilder
    private func editToolbar(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize) -> some View {
        let yPos: CGFloat = isPortrait && gameRect.height > 0
            ? gameRect.origin.y + gameRect.height + 8 + 20
            : safeArea.top + 4 + 20

        HStack(spacing: Spacing.xl) {
            Button("+ Add") { showAddSheet = true }
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
            Button("Reset") { showResetConfirm = true }
                .foregroundStyle(.brand)
                .font(.system(size: 14, weight: .semibold))
            Button("Done") { toggleEditMode() }
                .foregroundStyle(.success)
                .font(.system(size: 14, weight: .bold))
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.black.opacity(Overlay.heavy))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .position(x: geoSize.width / 2, y: yPos)
    }

    // MARK: - Layout Helpers

    private func toolbarOrigin(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize, btnSize: CGFloat, gap: CGFloat, count: CGFloat) -> CGPoint {
        let totalW = count * btnSize + (count - 1) * gap
        if isPortrait && gameRect.height > 0 {
            // Right-aligned, just below game
            let x = geoSize.width - safeArea.trailing - 8 - totalW / 2
            let y = gameRect.origin.y + gameRect.height + 8 + btnSize / 2
            return CGPoint(x: x, y: y)
        } else {
            // Landscape: top-right
            let x = geoSize.width - safeArea.trailing - 4 - totalW / 2
            let y = safeArea.top + 4 + btnSize / 2
            return CGPoint(x: x, y: y)
        }
    }

    private func debugOverlayPosition(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets) -> CGPoint {
        if isPortrait && gameRect.height > 0 {
            return CGPoint(x: safeArea.leading + 4 + 110, y: gameRect.origin.y + gameRect.height + 8 + 50)
        } else {
            return CGPoint(x: safeArea.leading + 4 + 110, y: safeArea.top + 4 + 50)
        }
    }

    private func absolutePosition(for relativeCenter: CGPoint, in size: CGSize, controlSize: CGSize, safeArea: EdgeInsets) -> CGPoint {
        let hw = controlSize.width * 0.5
        let hh = controlSize.height * 0.5
        let minX = safeArea.leading + hw
        let minY = safeArea.top + hh
        let maxX = size.width - safeArea.trailing - hw
        let maxY = size.height - safeArea.bottom - hh
        let cx = max(minX, min(relativeCenter.x * size.width, maxX))
        let cy = max(minY, min(relativeCenter.y * size.height, maxY))
        return CGPoint(x: cx, y: cy)
    }

    private func clampToSafeArea(_ point: CGPoint, controlSize: CGFloat, in geo: GeometryProxy) -> CGPoint {
        let safe = geo.safeAreaInsets
        let hw = controlSize * 0.5
        let x = max(safe.leading + hw, min(point.x, geo.size.width - safe.trailing - hw))
        let y = max(safe.top + hw, min(point.y, geo.size.height - safe.bottom - hw))
        return CGPoint(x: x, y: y)
    }

    // MARK: - Actions

    private func toggleEditMode() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
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

    private func resetToolbarIdleTimer() {
        toolbarIdleTask?.cancel()
        if toolbarOpacity < 1 {
            withAnimation(.spring(duration: Motion.durationFast, bounce: 0)) {
                toolbarOpacity = 1.0
            }
        }
        toolbarIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(kToolbarIdleDelay))
            guard !Task.isCancelled else { return }
            if !editMode && !controlsHidden {
                withAnimation(.spring(duration: Motion.durationSlow, bounce: 0)) {
                    toolbarOpacity = 0.5
                }
            }
        }
    }

    /// Fade the snapshot to reveal the live SDL surface.
    private func startSnapshotFade() {
        withAnimation(.spring(duration: Motion.durationNormal, bounce: 0)) {
            snapshotOpacity = 0
            controlsVisible = true
        }
        resetToolbarIdleTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            resumeSnapshot = nil
            pauseManager.pauseSnapshot = nil
            pauseManager.snapshotCanFade = false
        }
    }
}
