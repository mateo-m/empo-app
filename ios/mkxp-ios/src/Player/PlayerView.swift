import SwiftUI
import Combine

// ============================================================================
// MARK: - Conditional View Modifier
// ============================================================================

extension View {
    /// Conditionally applies a modifier. When `condition` is false, the view
    /// is returned unmodified — no gesture recognizers or other side-effects.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// ============================================================================
// MARK: - Key Catalog
// ============================================================================

struct KeyEntry: Identifiable {
    let id = UUID()
    let label: String
    let scancode: Int32
}

let keyCatalog: [KeyEntry] = [
    // Common RPG Maker keys
    KeyEntry(label: "Z (Confirm)",  scancode: Int32(MKXP_SCANCODE_Z)),
    KeyEntry(label: "X (Cancel)",   scancode: Int32(MKXP_SCANCODE_X)),
    KeyEntry(label: "Shift (Dash)", scancode: Int32(MKXP_SCANCODE_LSHIFT)),
    KeyEntry(label: "Ctrl (Skip)",  scancode: Int32(MKXP_SCANCODE_LCTRL)),
    KeyEntry(label: "Space",        scancode: Int32(MKXP_SCANCODE_SPACE)),
    KeyEntry(label: "Enter",        scancode: Int32(MKXP_SCANCODE_RETURN)),
    KeyEntry(label: "Escape",       scancode: Int32(MKXP_SCANCODE_ESCAPE)),
    KeyEntry(label: "Tab",          scancode: Int32(MKXP_SCANCODE_TAB)),
    // Letters
    KeyEntry(label: "A", scancode: Int32(MKXP_SCANCODE_A)),
    KeyEntry(label: "B", scancode: Int32(MKXP_SCANCODE_B)),
    KeyEntry(label: "C", scancode: Int32(MKXP_SCANCODE_C)),
    KeyEntry(label: "D", scancode: Int32(MKXP_SCANCODE_D)),
    KeyEntry(label: "E", scancode: Int32(MKXP_SCANCODE_E)),
    KeyEntry(label: "F", scancode: Int32(MKXP_SCANCODE_F)),
    KeyEntry(label: "G", scancode: Int32(MKXP_SCANCODE_G)),
    KeyEntry(label: "H", scancode: Int32(MKXP_SCANCODE_H)),
    KeyEntry(label: "I", scancode: Int32(MKXP_SCANCODE_I)),
    KeyEntry(label: "J", scancode: Int32(MKXP_SCANCODE_J)),
    KeyEntry(label: "K", scancode: Int32(MKXP_SCANCODE_K)),
    KeyEntry(label: "L", scancode: Int32(MKXP_SCANCODE_L)),
    KeyEntry(label: "M", scancode: Int32(MKXP_SCANCODE_M)),
    KeyEntry(label: "N", scancode: Int32(MKXP_SCANCODE_N)),
    KeyEntry(label: "O", scancode: Int32(MKXP_SCANCODE_O)),
    KeyEntry(label: "P", scancode: Int32(MKXP_SCANCODE_P)),
    KeyEntry(label: "Q", scancode: Int32(MKXP_SCANCODE_Q)),
    KeyEntry(label: "R", scancode: Int32(MKXP_SCANCODE_R)),
    KeyEntry(label: "S", scancode: Int32(MKXP_SCANCODE_S)),
    KeyEntry(label: "T", scancode: Int32(MKXP_SCANCODE_T)),
    KeyEntry(label: "U", scancode: Int32(MKXP_SCANCODE_U)),
    KeyEntry(label: "V", scancode: Int32(MKXP_SCANCODE_V)),
    KeyEntry(label: "W", scancode: Int32(MKXP_SCANCODE_W)),
    KeyEntry(label: "Y", scancode: Int32(MKXP_SCANCODE_Y)),
    // Numbers
    KeyEntry(label: "0", scancode: Int32(MKXP_SCANCODE_0)),
    KeyEntry(label: "1", scancode: Int32(MKXP_SCANCODE_1)),
    KeyEntry(label: "2", scancode: Int32(MKXP_SCANCODE_2)),
    KeyEntry(label: "3", scancode: Int32(MKXP_SCANCODE_3)),
    KeyEntry(label: "4", scancode: Int32(MKXP_SCANCODE_4)),
    KeyEntry(label: "5", scancode: Int32(MKXP_SCANCODE_5)),
    KeyEntry(label: "6", scancode: Int32(MKXP_SCANCODE_6)),
    KeyEntry(label: "7", scancode: Int32(MKXP_SCANCODE_7)),
    KeyEntry(label: "8", scancode: Int32(MKXP_SCANCODE_8)),
    KeyEntry(label: "9", scancode: Int32(MKXP_SCANCODE_9)),
    // Function keys
    KeyEntry(label: "F1",  scancode: Int32(MKXP_SCANCODE_F1)),
    KeyEntry(label: "F2",  scancode: Int32(MKXP_SCANCODE_F2)),
    KeyEntry(label: "F3",  scancode: Int32(MKXP_SCANCODE_F3)),
    KeyEntry(label: "F4",  scancode: Int32(MKXP_SCANCODE_F4)),
    KeyEntry(label: "F5",  scancode: Int32(MKXP_SCANCODE_F5)),
    KeyEntry(label: "F6",  scancode: Int32(MKXP_SCANCODE_F6)),
    KeyEntry(label: "F7",  scancode: Int32(MKXP_SCANCODE_F7)),
    KeyEntry(label: "F8",  scancode: Int32(MKXP_SCANCODE_F8)),
    KeyEntry(label: "F9",  scancode: Int32(MKXP_SCANCODE_F9)),
    KeyEntry(label: "F10", scancode: Int32(MKXP_SCANCODE_F10)),
    KeyEntry(label: "F11", scancode: Int32(MKXP_SCANCODE_F11)),
    KeyEntry(label: "F12", scancode: Int32(MKXP_SCANCODE_F12)),
    // Special
    KeyEntry(label: "Alt",       scancode: Int32(MKXP_SCANCODE_LALT)),
    KeyEntry(label: "Backspace", scancode: Int32(MKXP_SCANCODE_BACKSPACE)),
]

// ============================================================================
// MARK: - Constants
// ============================================================================

private let kSmallButtonSize: CGFloat = 38
private let kToolbarIdleDelay: TimeInterval = 3.0

// ============================================================================
// MARK: - PlayerView
// ============================================================================

struct PlayerView: View {
    @Bindable var appState: AppState
    var layout: ControlsLayout
    @State private var editMode = false
    @State private var controlsHidden = false
    @State private var keyboardMode = false
    @State private var showDebugOverlay = false
    @State private var toolbarOpacity: Double = 1.0
    @State private var toolbarIdleTask: Task<Void, Never>?

    // Edit mode state
    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var editingButton: ButtonModel?
    @State private var showEditMenu = false
    @State private var showLabelEditor = false
    @State private var showKeyPicker = false
    @State private var showSizePicker = false
    @State private var editLabelText = ""

    // Drag state
    @State private var draggedDPad = false
    @State private var draggedButtonID: UUID?

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height > geo.size.width
            let gameRect = appState.gameRect
            let safeArea = geo.safeAreaInsets

            ZStack {
                // Transparent background — passes touches through to SDL
                Color.clear
                    .allowsHitTesting(false)

                if !controlsHidden {
                    // D-Pad
                    dpadView(in: geo)

                    // Action buttons
                    ForEach(layout.buttons) { button in
                        actionButtonView(button: button, in: geo)
                    }
                }

                // Toolbar (always visible unless editing)
                if !editMode {
                    toolbarButtons(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
                } else {
                    editToolbar(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoSize: geo.size)
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
            }
            .allowsHitTesting(true)
        }
        .ignoresSafeArea()
        .onAppear {
            TCInstallKeyEventWatcher()
            resetToolbarIdleTimer()
        }
        .alert("Return to Library", isPresented: $appState.showQuitConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Quit", role: .destructive) {
                appState.confirmQuit()
            }
        } message: {
            Text("Are you sure you want to quit the current game?")
        }
        .confirmationDialog("Add Button", isPresented: $showAddSheet) {
            ForEach(keyCatalog) { entry in
                Button(entry.label) {
                    layout.addButton(label: entry.label, scancode: entry.scancode)
                }
            }
        }
        .alert("Reset Controls", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    layout.resetToDefaults()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restore default layout?")
        }
        .confirmationDialog("Edit Button", isPresented: $showEditMenu) {
            if let btn = editingButton {
                Button("Change Label") {
                    editLabelText = btn.label
                    showLabelEditor = true
                }
                Button("Change Key (now: \(scancodeDisplayName(btn.scancode)))") {
                    showKeyPicker = true
                }
                Button("Change Size (now: \(Int(btn.size)))") {
                    showSizePicker = true
                }
                Button("Delete", role: .destructive) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        layout.removeButton(id: btn.id)
                    }
                }
            }
        }
        .alert("Button Label", isPresented: $showLabelEditor) {
            TextField("Label", text: $editLabelText)
            Button("OK") {
                if let btn = editingButton, !editLabelText.isEmpty {
                    layout.updateButton(id: btn.id, label: editLabelText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the text to display on this button")
        }
        .confirmationDialog("Emulated Key", isPresented: $showKeyPicker) {
            if let btn = editingButton {
                ForEach(keyCatalog) { entry in
                    let prefix = entry.scancode == btn.scancode ? "\u{2713} " : ""
                    Button("\(prefix)\(entry.label)") {
                        layout.updateButton(id: btn.id, scancode: entry.scancode)
                    }
                }
            }
        }
        .confirmationDialog("Button Size", isPresented: $showSizePicker) {
            if let btn = editingButton {
                let sizes: [(String, CGFloat)] = [
                    ("Small (38)", 38), ("Medium (50)", 50),
                    ("Default (56)", 56), ("Large (68)", 68), ("XL (80)", 80),
                ]
                ForEach(sizes, id: \.1) { name, size in
                    let prefix = Int(size) == Int(btn.size) ? "\u{2713} " : ""
                    Button("\(prefix)\(name)") {
                        layout.updateButton(id: btn.id, size: size)
                    }
                }
            }
        }
    }

    // MARK: - D-Pad

    @ViewBuilder
    private func dpadView(in geo: GeometryProxy) -> some View {
        let size = layout.dpadSize
        let pos = absolutePosition(for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size), safeArea: geo.safeAreaInsets)

        DPadRepresentable(size: size, editing: editMode)
            .frame(width: size, height: size)
            .position(pos)
            .if(editMode) { view in
                view.gesture(dpadDragGesture(in: geo))
            }
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
        .if(editMode) { view in
            view
                .gesture(buttonDragGesture(id: button.id, size: button.size, in: geo))
                .onTapGesture {
                    editingButton = button
                    showEditMenu = true
                }
        }
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
        let btnSize = isPortrait && gameRect.height > 0 ? kSmallButtonSize - 8 : kSmallButtonSize
        let iconPt: CGFloat = isPortrait && gameRect.height > 0 ? 13 : 16
        let gap: CGFloat = isPortrait ? 6 : 8

        let buttons: [(icon: String, action: () -> Void, tint: Color)] = {
            var list: [(icon: String, action: () -> Void, tint: Color)] = [
                ("keyboard", { toggleKeyboard() }, .white.opacity(0.8)),
            ]
            if AppSettings.shared.debugMode {
                list.append(("chart.line.uptrend.xyaxis", { showDebugOverlay.toggle() }, .white.opacity(0.8)))
            }
            list.append(contentsOf: [
                ("gearshape.fill", { toggleEditMode() }, .white.opacity(0.8)),
                (controlsHidden ? "eye.slash.fill" : "eye.fill", { toggleHideControls() }, .white.opacity(0.8)),
            ])
            if AppSettings.shared.isEnabled(.gameQuit) {
                list.append(("xmark.circle.fill", { appState.requestQuit() }, Color(red: 1.0, green: 0.4, blue: 0.4)))
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
                        .foregroundColor(entry.tint)
                        .frame(width: btnSize, height: btnSize)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
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

        HStack(spacing: 16) {
            Button("+ Add") { showAddSheet = true }
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .semibold))
            Button("Reset") { showResetConfirm = true }
                .foregroundColor(.brand)
                .font(.system(size: 14, weight: .semibold))
            Button("Done") { toggleEditMode() }
                .foregroundColor(.green)
                .font(.system(size: 14, weight: .bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
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
            withAnimation(.easeInOut(duration: 0.15)) {
                toolbarOpacity = 1.0
            }
        }
        toolbarIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(kToolbarIdleDelay))
            guard !Task.isCancelled else { return }
            if !editMode && !controlsHidden {
                withAnimation(.easeInOut(duration: 0.6)) {
                    toolbarOpacity = 0.5
                }
            }
        }
    }

    private func scancodeDisplayName(_ sc: Int32) -> String {
        for entry in keyCatalog {
            if entry.scancode == sc { return entry.label }
        }
        return "Key \(sc)"
    }
}

// ============================================================================
// MARK: - Debug Overlay (SwiftUI)
// ============================================================================

struct DebugOverlayView: View {
    @State private var fps: Double = 0
    @State private var gameTitle: String = "--"
    @State private var rgssVersion: Int32 = 0
    @State private var ringBuffer = FPSRingBuffer(capacity: 120)
    @State private var metadataLoaded = false
    private let maxFPS: Double = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(gameTitle)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Text(rgssVersion > 0 ? "Ruby 1.8 \u{00B7} RGSS\(rgssVersion)" : "Ruby 1.8")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            Text(mkxp_isGameReady() != 0 ? "Running" : "Loading\u{2026}")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(mkxp_isGameReady() != 0 ? .green : .yellow)

            HStack(spacing: 4) {
                Text("\(Int(fps.rounded())) FPS")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(fpsColor)

                // FPS Graph
                Canvas { context, size in
                    let samples = ringBuffer.samples
                    guard samples.count >= 2 else { return }
                    var path = Path()
                    for (i, sample) in samples.enumerated() {
                        let x = CGFloat(i) / CGFloat(ringBuffer.capacity - 1) * size.width
                        let y = size.height - (sample / maxFPS) * size.height
                        let clamped = max(0, min(size.height, y))
                        if i == 0 { path.move(to: CGPoint(x: x, y: clamped)) }
                        else { path.addLine(to: CGPoint(x: x, y: clamped)) }
                    }
                    context.stroke(path, with: .color(fpsColor), lineWidth: 1.5)
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard mkxp_isEngineTerminated() == 0 else { return }
            fps = mkxp_getAverageFPS()
            ringBuffer.append(fps)

            // Load metadata once (title/version don't change mid-session)
            if !metadataLoaded {
                rgssVersion = mkxp_getRGSSVersion()
                if let title = mkxp_getGameTitle(), title[0] != 0 {
                    gameTitle = String(cString: title)
                    metadataLoaded = true
                }
            }
        }
    }

    private var fpsColor: Color {
        if fps >= 55 { return .green }
        if fps >= 30 { return .yellow }
        return .red
    }
}

/// Fixed-size ring buffer for FPS samples. O(1) append, no array shifting.
private struct FPSRingBuffer {
    let capacity: Int
    private var buffer: [Double]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Double](repeating: 0, count: capacity)
    }

    mutating func append(_ value: Double) {
        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Returns samples in chronological order (oldest first).
    var samples: [Double] {
        if count < capacity {
            return Array(buffer[0..<count])
        }
        // Ring wrapped: oldest is at writeIndex, read to end then wrap
        return Array(buffer[writeIndex..<capacity]) + Array(buffer[0..<writeIndex])
    }
}
