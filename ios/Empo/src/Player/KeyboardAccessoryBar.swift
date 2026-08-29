import SwiftUI

// The strip of game keys above the system keyboard, rendered with
// SwiftUI + the Liquid Glass material to match the on-screen controls
// in GameControls.swift.
//
// The bar floats: a rounded container with a margin to the screen
// edges and a gap above the keyboard. It follows the app theme, so
// it always matches the system keyboard under it.
//
// Layout follows the system keyboard's own pattern: every visible
// key gets an equal share of the row width, and the keys split into
// two balanced rows (one row when few keys remain). Nothing scrolls,
// so every key stays one tap away.
//
// The bar only lists keys the player cannot reach any other way:
//   - Enter, Backspace, and every typeable character are not here,
//     because the system keyboard under the bar already has them.
//   - Keys the visible on-screen controls or a connected controller
//     cover are filtered out. The host view refreshes that set on
//     every keyboard presentation.
//
// Key semantics:
//   - Tap keys (F1-F12, Esc, Tab) fire once, on a confirmed
//     touch-up. The injected press spans a 120 ms floor so it covers
//     at least one engine frame on a slow scene.
//   - Modifier keys (Ctrl, Shift, Alt) hold while the finger stays
//     down, like a hardware keyboard. A long press locks the key
//     down, shown as a solid accent key cap. A tap on a locked key
//     releases it. The lock makes combos like Alt+F8 possible with
//     one finger, and covers games that treat a modifier as a plain
//     key (Anil toggles turbo on Alt).
//   - Arrow keys hold while the finger stays down.
//   - Every press goes through `EngineSessionCoordinator.holdKey/
//     releaseKey`, so the bar shares the same per-key holder
//     ref-counting as the D-pad, buttons, and hardware keyboards.
//   - `releaseAll()` runs when the bar leaves the window (keyboard
//     dismissed) and on view teardown, so no key can stay stuck.

// MARK: - Key state

/// Tracks which keys the bar holds at the engine, including locked
/// modifiers. Owned by `KeyboardAccessoryHostView`, which releases
/// everything when the bar leaves the window.
@MainActor
@Observable
final class KeyboardAccessoryKeyState {
    /// True while the keyboard, and so the bar, is on screen. Drives
    /// the enter and exit transition: the bar fades and blurs out on
    /// dismissal, and plays the inverse on presentation.
    var visible = false

    /// Scancodes of locked modifiers, for the lit visual.
    private(set) var latched: Set<Int32> = []

    /// Scancodes the bar hides because another input path already
    /// covers them.
    private(set) var excluded: Set<Int32> = []

    /// Holder per held scancode. The bar never presses one scancode
    /// from two keys, so scancode is a sufficient map key.
    private var held: [Int32: KeyHolder] = [:]
    private var pressStarts: [Int32: ContinuousClock.Instant] = [:]

    /// Floor for a key's hold time. Heavy scenes poll input well
    /// below 40 fps. A shorter press can fall between two polls, and
    /// the game never sees the key.
    private static let tapHold: Duration = .milliseconds(120)

    func press(_ key: AccessoryKey) {
        let holder = KeyHolder.touch("acckey:\(key.id)")
        held[key.scancode] = holder
        pressStarts[key.scancode] = .now
        EngineSessionCoordinator.shared.holdKey(scancode: key.scancode, by: holder)
    }

    /// Releases the key. The hold stays alive until the `tapHold`
    /// floor has passed.
    func release(_ key: AccessoryKey) {
        guard let holder = held.removeValue(forKey: key.scancode) else { return }
        let started = pressStarts.removeValue(forKey: key.scancode)

        let elapsed = started.map { ContinuousClock.now - $0 } ?? Self.tapHold
        let remaining = Self.tapHold - elapsed
        guard remaining > .zero else {
            EngineSessionCoordinator.shared.releaseKey(scancode: key.scancode, by: holder)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: remaining)
            // After a releaseAll the holder is already gone and this
            // release is a no-op at the coordinator.
            EngineSessionCoordinator.shared.releaseKey(scancode: key.scancode, by: holder)
        }
    }

    /// One full press for a tap key: press now, release after the
    /// floor.
    func tap(_ key: AccessoryKey) {
        press(key)
        release(key)
    }

    /// Marks a held modifier as locked. The key is already down from
    /// the touch, so there is no extra press here.
    func latch(_ key: AccessoryKey) {
        latched.insert(key.scancode)
    }

    /// Unlocks the modifier and releases its hold.
    func unlatch(_ key: AccessoryKey) {
        guard latched.remove(key.scancode) != nil else { return }
        release(key)
    }

    /// Swaps the hidden-key set. A key that becomes hidden while
    /// held or locked releases at once, because its key cap is about
    /// to disappear.
    func setExcluded(_ scancodes: Set<Int32>) {
        excluded = scancodes
        for (scancode, holder) in held where scancodes.contains(scancode) {
            EngineSessionCoordinator.shared.releaseKey(scancode: scancode, by: holder)
            held.removeValue(forKey: scancode)
            pressStarts.removeValue(forKey: scancode)
            latched.remove(scancode)
        }
    }

    /// Drops every held key and clears the locks. The keyboard can
    /// dismiss while a key is held, and no touch-up arrives after
    /// that, so the host view calls this on window removal.
    func releaseAll() {
        for (scancode, holder) in held {
            EngineSessionCoordinator.shared.releaseKey(scancode: scancode, by: holder)
        }
        held.removeAll()
        pressStarts.removeAll()
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
    /// VoiceOver name. The visible face alone reads as a bare letter
    /// or symbol, which gives no hint that it is a game key.
    let name: String

    static func fKey(_ number: Int32) -> AccessoryKey {
        AccessoryKey(
            id: "F\(number)",
            face: .text("F\(number)"),
            scancode: Int32(MKXP_SCANCODE_F1) + number - 1,
            kind: .tap,
            name: "F\(number) key"
        )
    }
}

// MARK: - Bar

struct KeyboardAccessoryBar: View {
    /// The accessory view's fixed height: the two-row container plus
    /// the gap above the keyboard. UIKit reads the frame once at
    /// creation and ignores later changes. When fewer keys remain,
    /// the container shrinks and pins to the bottom of this space.
    static let height: CGFloat = 80 + Spacing.md

    /// Keys stay in one row up to this count. Beyond it, the split
    /// into two rows keeps every key cap wide enough to hit.
    private static let singleRowLimit = 8

    @Environment(\.colorScheme) private var colorScheme

    let keys: KeyboardAccessoryKeyState

    /// Everything the bar can show, most-used last so the balanced
    /// split puts modifiers and arrows in the bottom row, nearest
    /// the thumbs. Enter, Backspace, and typeable characters are
    /// absent on purpose: the system keyboard under the bar covers
    /// them.
    private static let allKeys: [AccessoryKey] =
        (1...12).map { .fKey(Int32($0)) } + [
            AccessoryKey(
                id: "esc", face: .symbol("escape"), scancode: Int32(MKXP_SCANCODE_ESCAPE),
                kind: .tap, name: "Escape key"),
            AccessoryKey(
                id: "tab", face: .symbol("arrow.right.to.line"),
                scancode: Int32(MKXP_SCANCODE_TAB),
                kind: .tap, name: "Tab key"),
            AccessoryKey(
                id: "ctrl", face: .text("Ctrl"), scancode: Int32(MKXP_SCANCODE_LCTRL),
                kind: .modifier, name: "Control key"),
            AccessoryKey(
                id: "shift", face: .text("Shift"), scancode: Int32(MKXP_SCANCODE_LSHIFT),
                kind: .modifier, name: "Shift key"),
            AccessoryKey(
                id: "alt", face: .text("Alt"), scancode: Int32(MKXP_SCANCODE_LALT),
                kind: .modifier, name: "Alt key"),
            AccessoryKey(
                id: "left", face: .symbol("chevron.left"), scancode: Int32(MKXP_SCANCODE_LEFT),
                kind: .hold, name: "Left arrow key"),
            AccessoryKey(
                id: "up", face: .symbol("chevron.up"), scancode: Int32(MKXP_SCANCODE_UP),
                kind: .hold, name: "Up arrow key"),
            AccessoryKey(
                id: "down", face: .symbol("chevron.down"), scancode: Int32(MKXP_SCANCODE_DOWN),
                kind: .hold, name: "Down arrow key"),
            AccessoryKey(
                id: "right", face: .symbol("chevron.right"),
                scancode: Int32(MKXP_SCANCODE_RIGHT),
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
                // Enter and exit transition. UIKit slides the whole
                // input stack, and the bare slide reads as a glitch
                // for a floating container. The fade + blur tracks
                // the keyboard: out on dismissal, in on presentation.
                .opacity(keys.visible ? 1 : 0)
                .blur(radius: keys.visible ? 0 : 10)
                .animation(Motion.standard, value: keys.visible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Spacing.md)
    }

    /// Balanced rows in the manner of the system keyboard: the split
    /// point is the middle, so no row ends up near-empty.
    private func rows(_ visible: [AccessoryKey]) -> [[AccessoryKey]] {
        guard visible.count > Self.singleRowLimit else { return [visible] }
        let split = (visible.count + 1) / 2
        return [Array(visible[..<split]), Array(visible[split...])]
    }

    /// Container backdrop in the tone of the system keyboard for the
    /// active theme.
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

/// Reports a Button's press edges, so press begins on touch-down
/// (hold keys need that) while the tap action still waits for a
/// confirmed touch-up.
private struct PressReportingStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in
                onPressChange(down)
            }
    }
}

/// One key cap: a theme-toned backing under Liquid Glass, a highlight
/// while pressed, a solid accent fill while locked, and the standard
/// press scale. The same visual language as `CircularControlButton`,
/// in key-cap shape. Every cap flexes to an equal share of its row.
private struct AccessoryKeyButton: View {
    let key: AccessoryKey
    let keys: KeyboardAccessoryKeyState

    /// How long a modifier must stay pressed before it locks down.
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
            // Runs on a confirmed touch-up inside the key. Tap keys
            // inject here, so a drag off the key fires nothing.
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
        .accessibilityValue(isLatched ? "locked" : "")
        .accessibilityHint(key.kind == .modifier ? "Touch and hold to lock the key down." : "")
        .onDisappear {
            latchTask?.cancel()
            latchTask = nil
            // The view can go away mid-press. A change in the hidden
            // set re-splits the rows, and a key that only MOVES rows
            // gets its view rebuilt, so no touch-up edge arrives. A
            // locked modifier keeps its hold on purpose: the lock
            // lives in the shared state and survives the rebuild.
            if isPressed && !isLatched {
                keys.release(key)
            }
            isPressed = false
        }
    }

    private var cap: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)

        return ZStack {
            // Opaque backing under glass, for the same reason as the
            // D-pad: with the game view embedded in AppWindow, Liquid
            // Glass otherwise samples the Metal layer on device.
            shape
                .fill(colorScheme == .dark ? Color.black : Color.white)

            Group {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: shape)
                } else {
                    shape
                        .fill(.clear)
                        .legacyGlassFallback(in: shape)
                }
            }

            // A locked modifier turns solid accent. This layer sits
            // above the glass: under it, the material washes the
            // brand color out.
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
            // Injection waits for the confirmed touch-up in the
            // Button action.
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
                // This touch only unlocked the key. The release
                // already happened on touch-down.
                unlatchedOnThisTouch = false
                return
            }
            if isLatched {
                // The long press locked the key during this touch.
                // Keep the hold alive after the finger lifts.
                return
            }
            keys.release(key)
        }
    }
}

// MARK: - UIKit host

/// UIKit container for the bar, assignable to a text field's
/// `inputAccessoryView`. Keeps a strong reference to the hosting
/// controller (a hosting view does not retain its controller) and
/// releases every held key when the keyboard dismisses.
final class KeyboardAccessoryHostView: UIView {
    private let keyState = KeyboardAccessoryKeyState()
    private let host: UIHostingController<KeyboardAccessoryBar>

    /// Scancodes to hide from the bar, asked fresh on every keyboard
    /// presentation: keys the visible on-screen controls or a
    /// connected controller already cover.
    var excludedScancodes: () -> Set<Int32> {
        didSet {
            if window != nil {
                keyState.setExcluded(excludedScancodes())
            }
        }
    }

    /// Fires before the dismissal animation, early enough for the
    /// exit transition to play while the input stack slides down.
    /// Window removal happens only after the slide, too late for it.
    private var hideObserver: NSObjectProtocol?

    init(excludedScancodes: @escaping () -> Set<Int32> = { [] }) {
        self.excludedScancodes = excludedScancodes
        host = UIHostingController(rootView: KeyboardAccessoryBar(keys: keyState))
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardAccessoryBar.height))
        autoresizingMask = [.flexibleWidth]

        // The hosting controller sees the keyboard frame overlap its
        // own view (the reported keyboard rect includes the accessory
        // area) and pads the content bottom to avoid it. That opened
        // a large gap between the bar and the keyboard. Keep only
        // the container region, which lifts the bar over the home
        // indicator when the accessory docks without a keyboard.
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
            // Re-read theme and coverage on every presentation. Both
            // can change between two keyboard sessions.
            applyAppTheme()
            keyState.setExcluded(excludedScancodes())
        }
    }

    /// The accessory view lives in the keyboard's window, and the
    /// theme override on `AppWindow` does not reach it. Mirror the
    /// app theme here so the bar matches the keyboard, which follows
    /// the first responder's traits.
    private func applyAppTheme() {
        overrideUserInterfaceStyle = AppSettings.shared.theme.userInterfaceStyle
    }
}
