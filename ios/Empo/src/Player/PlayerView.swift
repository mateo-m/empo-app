import SwiftUI


private let kToolbarIdleDelay: TimeInterval = 3.0
private let kControlsZonePadding: CGFloat = 12.0
private let kControlsZoneInnerPadding: CGFloat = 6.0
private let kToolbarGap: CGFloat = 8.0
private let kToolbarEdgePad: CGFloat = 4.0
private let kToolbarPortraitSizeReduce: CGFloat = 8.0
private let kEditToolbarHalfHeight: CGFloat = 20.0
private let kMinLandscapeInset: CGFloat = 12.0
private let kFallbackDeviceCornerRadius: CGFloat = 55.0
private let kDragScaleFactor: CGFloat = 1.08


struct PlayerView: View {
    @Bindable var appState: AppState
    @Bindable var engineState: EngineState
    var layout: ControlsLayout
    var pauseManager = PauseManager.shared
    @State private var editMode = false
    @State private var controlsHidden = false
    @State private var keyboardMode = false
    @State private var showDebugOverlay = false
    @State private var debugOverlayOffset: CGSize = .zero
    @State private var debugOverlayDragOffset: CGSize = .zero
    @State private var toolbarOpacity: Double = 1.0
    @State private var toolbarIdleTask: Task<Void, Never>?
    @State private var showQuitConfirm = false

    @State private var resumeSnapshot: UIImage?
    @State private var snapshotOpacity: Double = 1
    @State private var controlsVisible: Bool = true

    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var editingButton: ButtonModel?
    @State private var draggingDPad = false
    @State private var draggingButtonID: UUID?

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let gameRect = engineState.gameRect
            let safeArea = AppWindow.currentSafeArea
            let overlay = useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geo.size.height)
            let toolbarBtnSize = isPortrait && gameRect.height > 0 && !overlay ? AppSize.toolbarButton - kToolbarPortraitSizeReduce : AppSize.toolbarButton
            let controlsMinY = toolbarBottomY(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, btnSize: toolbarBtnSize, geoHeight: geo.size.height)

            ZStack {
                if editMode {
                    editZoneBackground(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geo.size)
                }

                if !controlsHidden && controlsVisible {
                    dpadView(in: geo, controlsMinY: controlsMinY)

                    ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, button in
                        actionButtonView(button: button, index: index, in: geo, controlsMinY: controlsMinY)
                    }
                }

                if controlsVisible {
                    toolbarButtons(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
                        .opacity(editMode ? 0 : 1)
                        .allowsHitTesting(!editMode)
                    editToolbar(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
                        .opacity(editMode ? 1 : 0)
                        .allowsHitTesting(editMode)
                }

                if showDebugOverlay {
                    DebugOverlayView()
                        .frame(width: AppSize.debugOverlayWidth, height: AppSize.debugOverlayHeight)
                        .position(debugOverlayPosition(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geo.size.height))
                        .offset(x: debugOverlayOffset.width + debugOverlayDragOffset.width,
                                y: debugOverlayOffset.height + debugOverlayDragOffset.height)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    debugOverlayDragOffset = clampDebugOverlayOffset(
                                        base: debugOverlayOffset,
                                        delta: value.translation,
                                        isPortrait: isPortrait,
                                        gameRect: gameRect,
                                        safeArea: safeArea,
                                        geoSize: geo.size
                                    )
                                }
                                .onEnded { value in
                                    let clamped = clampDebugOverlayOffset(
                                        base: debugOverlayOffset,
                                        delta: value.translation,
                                        isPortrait: isPortrait,
                                        gameRect: gameRect,
                                        safeArea: safeArea,
                                        geoSize: geo.size
                                    )
                                    debugOverlayOffset.width += clamped.width
                                    debugOverlayOffset.height += clamped.height
                                    debugOverlayDragOffset = .zero
                                }
                        )
                        .transition(.opacity)
                        .onChange(of: geo.size) {
                        // Orientation/size change: re-clamp so the overlay
                        // stays inside the new safe area bounds.
                        debugOverlayOffset = clampDebugOverlayOffset(
                            base: .zero,
                            delta: debugOverlayOffset,
                            isPortrait: isPortrait,
                            gameRect: gameRect,
                            safeArea: safeArea,
                            geoSize: geo.size
                        )
                    }
                }

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
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("Are you sure you want to quit the current game?")
        }
        .tint(nil)
        .controlsEditDialogs(
            layout: layout,
            showAddSheet: $showAddSheet,
            showResetConfirm: $showResetConfirm,
            editingButton: $editingButton
        )
    }


    @ViewBuilder
    private func dpadView(in geo: GeometryProxy, controlsMinY: CGFloat) -> some View {
        let size = layout.dpadSize
        let pos = absolutePosition(for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size), safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY)
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)

        DPadRepresentable(size: size, editing: editMode, dragging: draggingDPad)
            .frame(width: size, height: size)
            .scaleEffect(draggingDPad ? kDragScaleFactor : 1.0)
            .animation(Motion.snappy, value: draggingDPad)
            .position(pos)
            .transition(.controlAppear(anchor: anchor))
            .gesture(dpadDragGesture(in: geo, controlsMinY: controlsMinY), including: editMode ? .all : .none)
    }

    private func dpadDragGesture(in geo: GeometryProxy, controlsMinY: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if !draggingDPad { draggingDPad = true }
                let newCenter = value.location
                let clamped = clampToSafeArea(newCenter, controlSize: layout.dpadSize, in: geo, controlsMinY: controlsMinY)
                layout.dpadRelativeCenter = CGPoint(
                    x: clamped.x / geo.size.width,
                    y: clamped.y / geo.size.height
                )
            }
            .onEnded { _ in
                draggingDPad = false
                layout.save()
            }
    }


    @ViewBuilder
    private func actionButtonView(button: ButtonModel, index: Int, in geo: GeometryProxy, controlsMinY: CGFloat) -> some View {
        let pos = absolutePosition(for: button.relativeCenter, in: geo.size, controlSize: CGSize(width: button.size, height: button.size), safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY)
        let isDragging = draggingButtonID == button.id
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)

        ActionButtonRepresentable(
            label: button.label,
            scancode: button.scancode,
            buttonSize: button.size,
            editing: editMode,
            dragging: isDragging
        )
        .frame(width: button.size, height: button.size)
        .onTapGesture {
            guard editMode else { return }
            editingButton = button
        }
        .overlay(alignment: .topTrailing) {
            if editMode && !isDragging {
                Button {
                    withAnimation(Motion.snappy) {
                        layout.removeButton(id: button.id)
                    }
                } label: {
                    Chip(systemImage: "xmark", tint: .destructive)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(isDragging ? kDragScaleFactor : 1.0)
        .animation(Motion.snappy, value: isDragging)
        .position(pos)
        .transition(.controlAppear(anchor: anchor))
        .gesture(buttonDragGesture(id: button.id, size: button.size, in: geo, controlsMinY: controlsMinY), including: editMode ? .all : .none)
    }

    private func buttonDragGesture(id: UUID, size: CGFloat, in geo: GeometryProxy, controlsMinY: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if draggingButtonID != id { draggingButtonID = id }
                let newCenter = value.location
                let clamped = clampToSafeArea(newCenter, controlSize: size, in: geo, controlsMinY: controlsMinY)
                layout.updateButton(id: id, relativeCenter: CGPoint(
                    x: clamped.x / geo.size.width,
                    y: clamped.y / geo.size.height
                ))
            }
            .onEnded { _ in
                draggingButtonID = nil
                layout.save()
            }
    }


    @ViewBuilder
    private func toolbarButtons(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize) -> some View {
        let overlay = useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoSize.height)
        let btnSize = isPortrait && gameRect.height > 0 && !overlay ? AppSize.toolbarButton - kToolbarPortraitSizeReduce : AppSize.toolbarButton
        let gap: CGFloat = isPortrait ? Spacing.sm : Spacing.md

        let buttons: [(icon: String, label: String, action: () -> Void, tint: Color?)] = {
            var list: [(icon: String, label: String, action: () -> Void, tint: Color?)] = []
            if AppSettings.shared.isEnabled(.gamePause) {
                list.append(("pause.fill", "Pause game", { appState.requestPause() }, .white))
            }
            list.append(("keyboard", "Toggle keyboard", { toggleKeyboard() }, .white))
            if AppSettings.shared.debugMode {
                list.append(("chart.line.uptrend.xyaxis", "Debug overlay", { showDebugOverlay.toggle() }, .white))
            }
            list.append(("gearshape.fill", "Edit controls", { toggleEditMode() }, .white))
            list.append((controlsHidden ? "eye.slash.fill" : "eye.fill", controlsHidden ? "Show controls" : "Hide controls", { toggleHideControls() }, .white))
            if AppSettings.shared.isEnabled(.gameQuit) {
                list.append(("xmark.circle.fill", "Quit game", { showQuitConfirm = true }, .destructive))
            }
            return list
        }()

        let toolbarPosition = toolbarOrigin(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geoSize, btnSize: btnSize, gap: gap, count: CGFloat(buttons.count))

        HStack(spacing: gap) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, entry in
                IconButton(
                    entry.icon,
                    style: .secondary,
                    size: btnSize,
                    tint: entry.tint
                ) {
                    resetToolbarIdleTimer()
                    entry.action()
                }
                .accessibilityLabel(entry.label)
            }
        }
        .opacity(toolbarOpacity)
        .position(toolbarPosition)
    }


    @ViewBuilder
    private func editToolbar(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize) -> some View {
        let overlay = useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoSize.height)
        let yPos: CGFloat = isPortrait && gameRect.height > 0 && !overlay
            ? gameRect.origin.y + gameRect.height + kToolbarGap + kEditToolbarHalfHeight
            : max(safeArea.top, kMinLandscapeInset) + kToolbarEdgePad + kEditToolbarHalfHeight

        HStack(spacing: Spacing.xl) {
            Button("+ Add") { showAddSheet = true }
                .accessibilityLabel("Add button")
                .foregroundStyle(.white)
                .font(.footnote.weight(.semibold))
            Button("Reset") { showResetConfirm = true }
                .foregroundStyle(.brand)
                .font(.footnote.weight(.semibold))
            Button("Done") { toggleEditMode() }
                .foregroundStyle(.success)
                .font(.footnote.weight(.bold))
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(Color.black.opacity(Overlay.heavy))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .position(x: geoSize.width / 2, y: yPos)
    }


    @ViewBuilder
    private func editZoneBackground(controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize) -> some View {
        let bounds = zoneBounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let radii = zoneCornerRadii(safeArea: safeArea)

        UnevenRoundedRectangle(
            topLeadingRadius: radii.top,
            bottomLeadingRadius: radii.bottom,
            bottomTrailingRadius: radii.bottom,
            topTrailingRadius: radii.top
        )
        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: radii.top,
                bottomLeadingRadius: radii.bottom,
                bottomTrailingRadius: radii.bottom,
                topTrailingRadius: radii.top
            )
            .fill(Color.black.opacity(Overlay.medium))
        )
        .frame(width: bounds.width, height: bounds.height)
        .position(x: bounds.midX, y: bounds.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func zoneBounds(controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize) -> CGRect {
        let pad = kControlsZonePadding
        let top = controlsMinY + pad
        let bottom = geoSize.height - safeArea.bottom - pad
        let leading = safeArea.leading + pad
        let trailing = geoSize.width - safeArea.trailing - pad
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }

    private func zoneCornerRadii(safeArea: EdgeInsets) -> (top: CGFloat, bottom: CGFloat) {
        let pad = kControlsZonePadding
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        let deviceCorner = (screen?.value(forKey: "displayCornerRadius") as? CGFloat) ?? kFallbackDeviceCornerRadius
        let horizontalGap = safeArea.leading + pad
        let bottomGap = safeArea.bottom + pad
        let minGap = min(horizontalGap, bottomGap)
        let bottom = max(deviceCorner - minGap, Radius.sm)
        let top = Radius.xl
        return (top, bottom)
    }


    private func toolbarOrigin(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoSize: CGSize, btnSize: CGFloat, gap: CGFloat, count: CGFloat) -> CGPoint {
        let totalW = count * btnSize + (count - 1) * gap
        if isPortrait && gameRect.height > 0 && !useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoSize.height) {
            let x = geoSize.width - safeArea.trailing - kToolbarGap - totalW / 2
            let y = gameRect.origin.y + gameRect.height + kToolbarGap + btnSize / 2
            return CGPoint(x: x, y: y)
        } else {
            let rightInset = max(safeArea.trailing, kMinLandscapeInset)
            let topInset = max(safeArea.top, kMinLandscapeInset)
            let x = geoSize.width - rightInset - kToolbarEdgePad - totalW / 2
            let y = topInset + kToolbarEdgePad + btnSize / 2
            return CGPoint(x: x, y: y)
        }
    }

    private func debugOverlayPosition(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoHeight: CGFloat) -> CGPoint {
        let halfW = AppSize.debugOverlayWidth / 2
        let halfH = AppSize.debugOverlayHeight / 2
        if isPortrait && gameRect.height > 0 && !useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoHeight) {
            return CGPoint(x: safeArea.leading + kToolbarEdgePad + halfW, y: gameRect.origin.y + gameRect.height + kToolbarGap + halfH)
        } else {
            let leftInset = max(safeArea.leading, kMinLandscapeInset)
            let topInset = max(safeArea.top, kMinLandscapeInset)
            return CGPoint(x: leftInset + kToolbarEdgePad + halfW, y: topInset + kToolbarEdgePad + halfH)
        }
    }

    /// Clamps the drag delta so the overlay's final position stays within safe-area bounds.
    /// Returns the adjusted delta (may differ from `delta` if the overlay would escape).
    private func clampDebugOverlayOffset(
        base: CGSize,
        delta: CGSize,
        isPortrait: Bool,
        gameRect: CGRect,
        safeArea: EdgeInsets,
        geoSize: CGSize
    ) -> CGSize {
        let anchor = debugOverlayPosition(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoSize.height)
        let halfW = AppSize.debugOverlayWidth / 2
        let halfH = AppSize.debugOverlayHeight / 2
        let minX = safeArea.leading + halfW
        let maxX = geoSize.width - safeArea.trailing - halfW
        let minY = safeArea.top + halfH
        let maxY = geoSize.height - safeArea.bottom - halfH

        let proposedX = anchor.x + base.width + delta.width
        let proposedY = anchor.y + base.height + delta.height
        let clampedX = max(minX, min(proposedX, maxX))
        let clampedY = max(minY, min(proposedY, maxY))

        return CGSize(width: clampedX - anchor.x - base.width,
                      height: clampedY - anchor.y - base.height)
    }

    /// Minimum vertical space below the game rect required to place the
    /// toolbar + controls in the dedicated zone below the game. When the
    /// game fills most of the screen (e.g. fixedAspectRatio off) there
    /// isn't enough room, so we fall back to overlay mode (same as
    /// landscape: toolbar at top, controls over the game).
    private static let kMinControlsZoneHeight: CGFloat = 120

    private func useOverlayLayout(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoHeight: CGFloat) -> Bool {
        guard isPortrait, gameRect.height > 0 else { return false }
        let spaceBelow = geoHeight - (gameRect.origin.y + gameRect.height) - safeArea.bottom
        return spaceBelow < Self.kMinControlsZoneHeight
    }

    private func toolbarBottomY(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, btnSize: CGFloat, geoHeight: CGFloat) -> CGFloat {
        if isPortrait && gameRect.height > 0 && !useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoHeight) {
            return gameRect.origin.y + gameRect.height + kToolbarGap + btnSize + kToolbarEdgePad
        } else {
            let topInset = max(safeArea.top, kMinLandscapeInset)
            return topInset + kToolbarEdgePad + btnSize + kToolbarEdgePad
        }
    }

    private func absolutePosition(for relativeCenter: CGPoint, in size: CGSize, controlSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat) -> CGPoint {
        let pad = kControlsZonePadding + kControlsZoneInnerPadding
        let hw = controlSize.width * 0.5
        let hh = controlSize.height * 0.5
        let minX = safeArea.leading + pad + hw
        let minY = max(safeArea.top + pad + hh, controlsMinY + pad + hh)
        let maxX = size.width - safeArea.trailing - pad - hw
        let maxY = size.height - safeArea.bottom - pad - hh
        let cx = max(minX, min(relativeCenter.x * size.width, maxX))
        let cy = max(minY, min(relativeCenter.y * size.height, maxY))
        let zone = zoneBounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: size)
        let radii = zoneCornerRadii(safeArea: safeArea)
        return clampToRoundedCorners(CGPoint(x: cx, y: cy), controlHalf: max(hw, hh), zone: zone, radii: radii)
    }

    private func clampToSafeArea(_ point: CGPoint, controlSize: CGFloat, in geo: GeometryProxy, controlsMinY: CGFloat) -> CGPoint {
        let safe = AppWindow.currentSafeArea
        let pad = kControlsZonePadding + kControlsZoneInnerPadding
        let hw = controlSize * 0.5
        let x = max(safe.leading + pad + hw, min(point.x, geo.size.width - safe.trailing - pad - hw))
        let minY = max(safe.top + pad + hw, controlsMinY + pad + hw)
        let y = max(minY, min(point.y, geo.size.height - safe.bottom - pad - hw))
        let zone = zoneBounds(controlsMinY: controlsMinY, safeArea: safe, geoSize: geo.size)
        let radii = zoneCornerRadii(safeArea: safe)
        return clampToRoundedCorners(CGPoint(x: x, y: y), controlHalf: hw, zone: zone, radii: radii)
    }

    private func clampToRoundedCorners(_ point: CGPoint, controlHalf: CGFloat, zone: CGRect, radii: (top: CGFloat, bottom: CGFloat)) -> CGPoint {
        var p = point
        let corners: [(cx: CGFloat, cy: CGFloat, r: CGFloat)] = [
            (zone.minX + radii.top, zone.minY + radii.top, radii.top),
            (zone.maxX - radii.top, zone.minY + radii.top, radii.top),
            (zone.minX + radii.bottom, zone.maxY - radii.bottom, radii.bottom),
            (zone.maxX - radii.bottom, zone.maxY - radii.bottom, radii.bottom),
        ]
        for corner in corners {
            let inCornerX = (p.x < corner.cx && corner.cx <= zone.minX + max(radii.top, radii.bottom))
                         || (p.x > corner.cx && corner.cx >= zone.maxX - max(radii.top, radii.bottom))
            let inCornerY = (p.y < corner.cy && corner.cy <= zone.minY + max(radii.top, radii.bottom))
                         || (p.y > corner.cy && corner.cy >= zone.maxY - max(radii.top, radii.bottom))
            guard inCornerX && inCornerY else { continue }
            let dx = p.x - corner.cx
            let dy = p.y - corner.cy
            let dist = sqrt(dx * dx + dy * dy)
            let maxDist = corner.r - controlHalf - kControlsZoneInnerPadding
            if maxDist > 0 && dist > maxDist {
                let scale = maxDist / dist
                p.x = corner.cx + dx * scale
                p.y = corner.cy + dy * scale
            }
        }
        return p
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

    private func resetToolbarIdleTimer() {
        toolbarIdleTask?.cancel()
        if toolbarOpacity < 1 {
            withAnimation(Motion.snappy) {
                toolbarOpacity = 1.0
            }
        }
        toolbarIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(kToolbarIdleDelay))
            guard !Task.isCancelled else { return }
            if !editMode && !controlsHidden {
                withAnimation(Motion.slow) {
                    toolbarOpacity = 0.5
                }
            }
        }
    }

    private func startSnapshotFade() {
        resetToolbarIdleTimer()
        withAnimation(Motion.standard) {
            snapshotOpacity = 0
            controlsVisible = true
        } completion: {
            // Tied to the fade completion instead of a wall-clock
            // asyncAfter so we always unmount the snapshot exactly
            // when the user no longer sees it, even if the spring
            // duration changes.
            resumeSnapshot = nil
            pauseManager.pauseSnapshot = nil
            pauseManager.snapshotCanFade = false
        }
    }
}
