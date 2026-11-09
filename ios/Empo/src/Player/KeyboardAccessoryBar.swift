// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

// MARK: - Key state

@MainActor
@Observable
final class KeyboardAccessoryKeyState {
    var visible = false

    private(set) var latched: Set<Int32> = []

    /// Keys that another input already covers.
    private(set) var excluded: Set<Int32> = []

    private var held: [Int32: KeyHolder] = [:]

    func press(_ key: AccessoryKey) {
        let holder = KeyHolder.touch("acckey:\(key.id)")
        held[key.scancode] = holder
        EngineSessionCoordinator.shared.holdKey(scancode: key.scancode, by: holder)
    }

    /// A new press of the key before the tap hold ends cancels the
    /// release.
    func release(_ key: AccessoryKey) {
        guard let holder = held.removeValue(forKey: key.scancode) else { return }
        EngineSessionCoordinator.shared.releaseKey(
            scancode: key.scancode, by: holder,
            notBefore: .milliseconds(HeldKeys<KeyHolder>.tapHoldMilliseconds))
    }

    func tap(_ key: AccessoryKey) {
        press(key)
        release(key)
    }

    /// The touch already holds the key.
    func latch(_ key: AccessoryKey) {
        latched.insert(key.scancode)
    }

    func unlatch(_ key: AccessoryKey) {
        guard latched.remove(key.scancode) != nil else { return }
        release(key)
    }

    /// A held key that becomes hidden releases at once, because no
    /// touch end comes from a key cap that is gone.
    func setExcluded(_ scancodes: Set<Int32>) {
        excluded = scancodes
        for (scancode, holder) in held where scancodes.contains(scancode) {
            EngineSessionCoordinator.shared.releaseKey(scancode: scancode, by: holder)
            held.removeValue(forKey: scancode)
            latched.remove(scancode)
        }
    }

    /// No touch end comes after the keyboard closes during a press.
    func releaseAll() {
        for (scancode, holder) in held {
            EngineSessionCoordinator.shared.releaseKey(scancode: scancode, by: holder)
        }
        held.removeAll()
        latched.removeAll()
    }
}

// MARK: - Key model

struct AccessoryKey: Identifiable {
    enum Kind {
        case tap
        case modifier
        case hold
    }

    enum Face {
        case text(String)
        case symbol(String)
    }

    let id: String
    let face: Face
    let scancode: Int32
    let kind: Kind
    let name: LocalizedStringResource

    static func fKey(_ number: Int32) -> AccessoryKey {
        AccessoryKey(
            id: "F\(number)",
            face: .text("F\(number)"),
            scancode: Int32(GAMECORE_SCANCODE_F1) + number - 1,
            kind: .tap,
            name: "F\(number) key"
        )
    }
}

// MARK: - Bar

struct KeyboardAccessoryBar: View {
    /// UIKit reads the frame of an accessory view once, when it makes
    /// the view, so this height fits two rows and the gap.
    static let height: CGFloat = 80 + Spacing.md

    private static let singleRowLimit = 8

    @Environment(\.colorScheme) private var colorScheme

    let keys: KeyboardAccessoryKeyState

    /// The keys used most come last, so the modifiers and arrows go in
    /// the bottom row. The system keyboard has Enter, Backspace, and
    /// the characters.
    private static let allKeys: [AccessoryKey] =
        (1...12).map { .fKey(Int32($0)) } + [
            AccessoryKey(
                id: "esc", face: .symbol("escape"), scancode: Int32(GAMECORE_SCANCODE_ESCAPE),
                kind: .tap, name: "Escape key"),
            AccessoryKey(
                id: "tab", face: .symbol("arrow.right.to.line"),
                scancode: Int32(GAMECORE_SCANCODE_TAB),
                kind: .tap, name: "Tab key"),
            AccessoryKey(
                id: "ctrl", face: .text("Ctrl"), scancode: Int32(GAMECORE_SCANCODE_LCTRL),
                kind: .modifier, name: "Control key"),
            AccessoryKey(
                id: "shift", face: .text("Shift"), scancode: Int32(GAMECORE_SCANCODE_LSHIFT),
                kind: .modifier, name: "Shift key"),
            AccessoryKey(
                id: "alt", face: .text("Alt"), scancode: Int32(GAMECORE_SCANCODE_LALT),
                kind: .modifier, name: "Alt key"),
            AccessoryKey(
                id: "left", face: .symbol("chevron.left"), scancode: Int32(GAMECORE_SCANCODE_LEFT),
                kind: .hold, name: "Left arrow key"),
            AccessoryKey(
                id: "up", face: .symbol("chevron.up"), scancode: Int32(GAMECORE_SCANCODE_UP),
                kind: .hold, name: "Up arrow key"),
            AccessoryKey(
                id: "down", face: .symbol("chevron.down"), scancode: Int32(GAMECORE_SCANCODE_DOWN),
                kind: .hold, name: "Down arrow key"),
            AccessoryKey(
                id: "right", face: .symbol("chevron.right"),
                scancode: Int32(GAMECORE_SCANCODE_RIGHT),
                kind: .hold, name: "Right arrow key"),
        ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        let visible = Self.allKeys.filter { !keys.excluded.contains($0.scancode) }

        Group {
            if !visible.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(rows(visible).enumerated()), id: \.offset) { _, row in
                        keyRow(row)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(backdrop)
                .clipShape(shape)
                .padding(.horizontal, Spacing.md)
                // UIKit slides the full input stack, and a bare slide
                // looks wrong for a floating container.
                .opacity(keys.visible ? 1 : 0)
                .blur(radius: keys.visible ? 0 : 10)
                .animation(Motion.standard, value: keys.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Spacing.md)
    }

    private func rows(_ visible: [AccessoryKey]) -> [[AccessoryKey]] {
        guard visible.count > Self.singleRowLimit else { return [visible] }
        let split = (visible.count + 1) / 2
        return [Array(visible[..<split]), Array(visible[split...])]
    }

    private var backdrop: Color {
        colorScheme == .dark
            ? Color(white: 0.08).opacity(0.96)
            : Color(white: 0.87).opacity(0.96)
    }

    private func keyRow(_ row: [AccessoryKey]) -> some View {
        HStack(spacing: 5) {
            ForEach(row) { key in
                AccessoryKeyButton(key: key, keys: keys)
            }
        }
    }
}

// MARK: - Key cap

/// Hold keys press on touch down. The button action of a tap key comes
/// only on a touch up inside the key.
private struct PressReportingStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in
                onPressChange(down)
            }
    }
}

private struct AccessoryKeyButton: View {
    let key: AccessoryKey
    let keys: KeyboardAccessoryKeyState

    private static let latchDelay: Duration = .milliseconds(500)

    @Environment(\.colorScheme) private var colorScheme

    @State private var isPressed = false
    @State private var latchTask: Task<Void, Never>?
    @State private var unlatchedOnThisTouch = false

    private var isLatched: Bool {
        key.kind == .modifier && keys.latched.contains(key.scancode)
    }

    var body: some View {
        Button {
            if key.kind == .tap {
                keys.tap(key)
            }
        } label: {
            cap
        }
        .buttonStyle(
            PressReportingStyle { down in
                isPressed = down
                if down {
                    touchBegan()
                } else {
                    touchEnded()
                }
            }
        )
        .accessibilityLabel(key.name)
        .accessibilityValue(
            isLatched
                ? Text("Locked", comment: "Spoken state of a keyboard key held down by Empo.")
                : Text(verbatim: "")
        )
        .accessibilityHint(
            key.kind == .modifier ? Text("Touch and hold to lock the key down.") : Text(verbatim: "")
        )
        .onDisappear {
            latchTask?.cancel()
            latchTask = nil
            // A key that moves to the other row gets a new view, and
            // no touch end comes. A locked modifier keeps its hold.
            if isPressed && !isLatched {
                keys.release(key)
            }
            isPressed = false
        }
    }

    private var cap: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)

        return ZStack {
            BackedGlass(shape: shape, backing: colorScheme == .dark ? .black : .white)

            // Under the glass, the material makes the brand color pale.
            shape
                .fill(Color.brand)
                .opacity(isLatched ? 1 : 0)
                .animation(Motion.instant, value: isLatched)

            shape
                .fill(litOverlay)
                .opacity(isPressed ? 1 : 0)
                .animation(Motion.instant, value: isPressed)

            face
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .scaleEffect(isPressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: isPressed)
        .contentShape(shape)
    }

    private var litOverlay: Color {
        colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.12)
    }

    private var face: some View {
        Group {
            switch key.face {
            case .text(let label):
                Text(label)
                    .font(.system(size: 13, weight: isLatched ? .bold : .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            case .symbol(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: isLatched ? .bold : .semibold))
            }
        }
        .foregroundStyle(faceColor)
        .padding(.horizontal, 2)
    }

    private var faceColor: Color {
        if isLatched { return .white }
        return colorScheme == .dark
            ? .white.opacity(isPressed ? 1.0 : 0.9)
            : .black.opacity(isPressed ? 1.0 : 0.85)
    }

    private func touchBegan() {
        Haptics.controllerTap()

        switch key.kind {
        case .tap:
            break
        case .hold:
            keys.press(key)
        case .modifier:
            if isLatched {
                keys.unlatch(key)
                unlatchedOnThisTouch = true
                return
            }
            keys.press(key)
            latchTask = Task { @MainActor in
                try? await Task.sleep(for: Self.latchDelay)
                guard !Task.isCancelled, isPressed else { return }
                keys.latch(key)
                Haptics.controllerTap()
            }
        }
    }

    private func touchEnded() {
        latchTask?.cancel()
        latchTask = nil

        switch key.kind {
        case .tap:
            break
        case .hold:
            keys.release(key)
        case .modifier:
            if unlatchedOnThisTouch {
                unlatchedOnThisTouch = false
                return
            }
            if isLatched {
                return
            }
            keys.release(key)
        }
    }
}

// MARK: - UIKit host

/// A hosting view does not keep its controller, so this view keeps it.
final class KeyboardAccessoryHostView: UIView {
    private let keyState = KeyboardAccessoryKeyState()
    private let host: UIHostingController<KeyboardAccessoryBar>

    var excludedScancodes: () -> Set<Int32> {
        didSet {
            if window != nil {
                keyState.setExcluded(excludedScancodes())
            }
        }
    }

    /// UIKit removes the view from the window only after the slide, too
    /// late for the exit transition.
    private var hideObserver: NSObjectProtocol?

    init(excludedScancodes: @escaping () -> Set<Int32> = { [] }) {
        self.excludedScancodes = excludedScancodes
        host = UIHostingController(rootView: KeyboardAccessoryBar(keys: keyState))
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardAccessoryBar.height))
        autoresizingMask = [.flexibleWidth]

        // The keyboard rect includes the accessory area, so the
        // hosting controller pads the bottom of the content to avoid
        // it. The container region still lifts the bar over the home
        // indicator when the accessory shows with no keyboard.
        host.safeAreaRegions = .container

        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)

        applyAppTheme()

        hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.keyState.visible = false
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            keyState.visible = true
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            keyState.visible = false
            keyState.releaseAll()
        } else {
            applyAppTheme()
            keyState.setExcluded(excludedScancodes())
        }
    }

    /// The accessory view is in the keyboard window, and the theme
    /// override on `AppWindow` does not reach it.
    private func applyAppTheme() {
        overrideUserInterfaceStyle = AppSettings.shared.theme.userInterfaceStyle
    }
}
