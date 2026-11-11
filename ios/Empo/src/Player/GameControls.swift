// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

// MARK: - Action button

struct ActionButton: View {
    let id: UUID
    let label: String
    let scancode: Int32
    let size: CGFloat
    let editing: Bool

    var body: some View {
        CircularControlButton(
            size: size,
            editing: editing,
            accessibilityLabel: String(
                localized: "\(label) button",
                comment:
                    "VoiceOver name of an on-screen game button. The placeholder is the label on the button, such as A."
            ),
            onPress: {
                EngineSessionCoordinator.shared.holdKey(
                    scancode: scancode, by: .touch("button:\(id)"))
            },
            onRelease: {
                EngineSessionCoordinator.shared.releaseKey(
                    scancode: scancode, by: .touch("button:\(id)"))
            },
            face: { isPressed in
                Text(label)
                    .font(
                        .system(size: size < 60 ? 12 : 16, weight: .semibold, design: .rounded)
                    )
                    .foregroundStyle(.white.opacity(isPressed ? 1.0 : 0.9))
            }
        )
    }
}

// MARK: - Function button

struct FunctionButton: View {
    let action: EmpoAction
    let size: CGFloat
    let editing: Bool
    let isActive: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    var body: some View {
        CircularControlButton(
            size: size,
            editing: editing,
            isActive: isActive,
            accessibilityLabel: action.localizedName,
            onPress: onPress,
            onRelease: onRelease,
            face: { isPressed in
                Image(systemName: action.symbolName)
                    .font(.system(size: size < 60 ? 16 : 20, weight: .semibold))
                    .foregroundStyle(
                        isActive ? Color.brand : .white.opacity(isPressed ? 1.0 : 0.9))
            }
        )
    }
}

// MARK: - Shared circular control

struct CircularControlButton<Face: View>: View {
    let size: CGFloat
    let editing: Bool
    var isActive: Bool = false
    let accessibilityLabel: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @ViewBuilder let face: (Bool) -> Face

    @State private var isPressed = false

    var body: some View {
        // `.interactive()` scales only the glass layer, not the content
        // on top of it. The scaleEffect on the ZStack scales the face too.
        ZStack {
            // Opaque backing: with the game view in AppWindow, Liquid
            // Glass otherwise samples the Metal layer on device.
            Circle()
                .fill(Color.black)

            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0), .white.opacity(0.28)],
                        center: .center,
                        startRadius: size * 0.15,
                        endRadius: size / 2
                    )
                )
                .opacity(isPressed || isActive ? 1 : 0)
                .animation(Motion.instant, value: isPressed)

            face(isPressed)
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: isPressed)
        .darkGlass()
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .overlay {
            ControlTouchCapture(
                enabled: !editing,
                onBegan: { _, _ in press() },
                // Slide-off keeps the key held.
                onMoved: { _, _ in },
                onEnded: { _, idle in
                    if idle {
                        releaseIfHeld()
                    }
                }
            )
        }
        .onChange(of: editing) { _, newValue in
            if newValue {
                releaseIfHeld()
            }
        }
        .onDisappear {
            releaseIfHeld()
        }
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        Haptics.controllerTap()
        onPress()
    }

    private func releaseIfHeld() {
        guard isPressed else { return }
        isPressed = false
        onRelease()
    }
}

// MARK: - D-pad

private struct MovementTouchState {
    var active: DPadTouchReducer.DirectionSet
    var touchPoint: CGPoint?
}

private struct MovementTouchHost<Visual: View>: View {
    let size: CGFloat
    let editing: Bool
    let style: MovementStyle
    @ViewBuilder let visual: (MovementTouchState) -> Visual

    @State private var reducer = DPadTouchReducer()

    var body: some View {
        visual(MovementTouchState(active: reducer.active, touchPoint: leadTouchPoint))
            .overlay {
                ControlTouchCapture(
                    enabled: !editing,
                    onBegan: { sample($0, at: $1) },
                    onMoved: { sample($0, at: $1) },
                    onEnded: { id, _ in apply(reducer.touchEnded(touch: id)) }
                )
            }
            .onChange(of: editing) { _, newValue in
                if newValue {
                    apply(reducer.releaseAll())
                }
            }
            .onDisappear {
                apply(reducer.releaseAll())
            }
    }

    private var leadTouchPoint: CGPoint? {
        reducer.leadTouchPoint.map { CGPoint(x: $0.x, y: $0.y) }
    }

    private func sample(_ id: Int, at point: CGPoint) {
        apply(
            reducer.touchChanged(
                touch: id, x: point.x, y: point.y, size: size,
                tuning: style.tuning(size: size)))
    }

    /// Keep the array order. The reducer puts releases first, so a
    /// wedge change never holds opposite directions at the same time.
    private func apply(_ edges: [DPadTouchReducer.Edge]) {
        for edge in edges {
            let holder = KeyHolder.touch("dpad:\(edge.direction)")
            if edge.pressed {
                EngineSessionCoordinator.shared.holdKey(
                    scancode: edge.direction.scancode, by: holder)
            } else {
                EngineSessionCoordinator.shared.releaseKey(
                    scancode: edge.direction.scancode, by: holder)
            }
        }
        if edges.contains(where: { $0.pressed }) {
            Haptics.controllerTap()
        }
    }
}

struct DPad: View {
    let size: CGFloat
    let editing: Bool

    /// Exactly one third. The grid snaps the D-pad size to a multiple
    /// of 30 pt, so each edge of the plus lands on the 10 pt grid.
    private let armFraction: CGFloat = 1.0 / 3.0

    private let cornerFraction: CGFloat = 0.25

    private let innerCornerFraction: CGFloat = 0.25

    var body: some View {
        MovementTouchHost(size: size, editing: editing, style: .dpad) { state in
            visual(active: state.active)
        }
    }

    private func visual(active: DPadTouchReducer.DirectionSet) -> some View {
        let plus = DPadPlusShape(
            armFraction: armFraction,
            cornerFraction: cornerFraction,
            innerCornerFraction: innerCornerFraction
        )
        let pressed = !active.isEmpty

        return ZStack {
            // Opaque backing: with the game view in AppWindow, Liquid
            // Glass otherwise samples the Metal layer. On device, it
            // then shows a clipped highlight at the top and left.
            plus
                .fill(Color.black)

            plus
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: plus)

            // Each highlight gets the frame of its own arm. On device, a
            // gradient on a shape that draws in one corner of the full
            // frame shows up and left differently from down and right.
            ZStack {
                ForEach(ControlDirection.allCases, id: \.self) { dir in
                    let arm = DPadArmGeometry.frame(
                        direction: dir, size: size, armFraction: armFraction)
                    let radii = DPadArmGeometry.cornerRadii(
                        direction: dir, size: size, armFraction: armFraction,
                        cornerFraction: cornerFraction)
                    UnevenRoundedRectangle(cornerRadii: radii)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0)],
                                startPoint: dir.localHighlightStart,
                                endPoint: dir.localHighlightEnd
                            )
                        )
                        .frame(width: arm.width, height: arm.height)
                        .position(x: arm.midX, y: arm.midY)
                        .opacity(active.contains(dir) ? 1 : 0)
                        .animation(Motion.instant, value: active)
                }
            }
            .clipShape(plus)

            ForEach(ControlDirection.allCases, id: \.self) { dir in
                Image(systemName: dir.symbolName)
                    .font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundStyle(.white.opacity(active.contains(dir) ? 1.0 : 0.55))
                    .offset(dir.glyphOffset(size: size, armFraction: armFraction))
            }

            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? PressScale.standard : 1.0)
        .animation(Motion.controlPress, value: pressed)
        // Without the dark variant, the plus shows brighter than the
        // circles of the buttons.
        .darkGlass()
        .contentShape(Circle())
        .accessibilityLabel("D-pad")
        .accessibilityHint("Touch and drag to move the character")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }
}

// MARK: - Joystick

struct Joystick: View {
    let size: CGFloat
    let editing: Bool

    /// Not tied to `MovementStickTuning.nubRatio`. The two values are
    /// equal only by chance.
    private let chevronDistanceRatio: CGFloat = 0.42

    private var nubSize: CGFloat {
        size * CGFloat(MovementStickTuning.nubRatio)
    }

    var body: some View {
        MovementTouchHost(size: size, editing: editing, style: .stick) { state in
            visual(active: state.active, touchPoint: state.touchPoint)
        }
    }

    private func visual(
        active: DPadTouchReducer.DirectionSet, touchPoint: CGPoint?
    ) -> some View {
        let pressed = !active.isEmpty
        // `active` is empty in the dead zone and past slide-off, so the
        // touch point picks the nub animation. A spring lags the finger.
        let touching = touchPoint != nil
        let thumbOffset =
            touchPoint.map { point in
                let offset = MovementStickTuning.thumbOffset(
                    x: point.x, y: point.y, size: size)
                return CGSize(width: offset.dx, height: offset.dy)
            } ?? .zero

        return ZStack {
            // Opaque backing: Liquid Glass otherwise samples the Metal layer.
            Circle()
                .fill(Color.black)

            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)

            ForEach(ControlDirection.allCases, id: \.self) { dir in
                Image(systemName: dir.symbolName)
                    .font(.system(size: size * 0.12, weight: .semibold))
                    .foregroundStyle(.white.opacity(active.contains(dir) ? 1.0 : 0.4))
                    .offset(chevronOffset(dir))
            }

            ZStack {
                Circle()
                    .fill(Color.black)
                Circle()
                    .fill(.white.opacity(pressed ? 0.35 : 0.2))
                Circle()
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            }
            .frame(width: nubSize, height: nubSize)
            .offset(thumbOffset)
            .animation(touching ? Motion.instant : Motion.snappy, value: thumbOffset)
        }
        .frame(width: size, height: size)
        .darkGlass()
        .contentShape(Circle())
        .accessibilityLabel("Joystick")
        .accessibilityHint("Touch and drag to move the character")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private func chevronOffset(_ dir: ControlDirection) -> CGSize {
        let distance = size * chevronDistanceRatio
        switch dir {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        }
    }
}

// MARK: - D-pad supporting types

extension ControlDirection {
    var scancode: Int32 {
        switch self {
        case .up: Int32(GAMECORE_SCANCODE_UP)
        case .down: Int32(GAMECORE_SCANCODE_DOWN)
        case .left: Int32(GAMECORE_SCANCODE_LEFT)
        case .right: Int32(GAMECORE_SCANCODE_RIGHT)
        }
    }

    var symbolName: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        }
    }

    /// Puts the chevron at the middle of the arm. The arm is
    /// `(size - armW) / 2` long, so its middle is `(size + armW) / 4`
    /// from the center.
    func glyphOffset(size: CGFloat, armFraction: CGFloat) -> CGSize {
        let d = (size + size * armFraction) / 4
        switch self {
        case .up: return CGSize(width: 0, height: -d)
        case .down: return CGSize(width: 0, height: d)
        case .left: return CGSize(width: -d, height: 0)
        case .right: return CGSize(width: d, height: 0)
        }
    }

    var localHighlightStart: UnitPoint {
        switch self {
        case .up: return .top
        case .down: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    var localHighlightEnd: UnitPoint {
        switch self {
        case .up: return .bottom
        case .down: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

// MARK: - D-pad decorative shapes

/// One closed path with no overlapping sub-paths. Two overlapping
/// rectangles show seams where they meet.
private struct DPadPlusShape: Shape {
    let armFraction: CGFloat
    let cornerFraction: CGFloat
    let innerCornerFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let armW = rect.width * armFraction
        let armH = rect.height * armFraction
        let cornerR = min(armW * cornerFraction, armW / 2, armH / 2)
        let hInset = (rect.height - armH) / 2  // y of horizontal bar top
        let vInset = (rect.width - armW) / 2  // x of vertical bar left
        let innerR = min(
            armW * innerCornerFraction,
            vInset / 2,
            hInset / 2,
            armW / 2,
            armH / 2
        )
        let w = rect.width
        let h = rect.height

        var p = Path()
        p.move(to: CGPoint(x: vInset, y: cornerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset + cornerR, y: 0),
            control: CGPoint(x: vInset, y: 0)
        )
        p.addLine(to: CGPoint(x: vInset + armW - cornerR, y: 0))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW, y: cornerR),
            control: CGPoint(x: vInset + armW, y: 0)
        )
        p.addLine(to: CGPoint(x: vInset + armW, y: hInset - innerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW + innerR, y: hInset),
            control: CGPoint(x: vInset + armW, y: hInset)
        )
        p.addLine(to: CGPoint(x: w - cornerR, y: hInset))
        p.addQuadCurve(
            to: CGPoint(x: w, y: hInset + cornerR),
            control: CGPoint(x: w, y: hInset)
        )
        p.addLine(to: CGPoint(x: w, y: hInset + armH - cornerR))
        p.addQuadCurve(
            to: CGPoint(x: w - cornerR, y: hInset + armH),
            control: CGPoint(x: w, y: hInset + armH)
        )
        p.addLine(to: CGPoint(x: vInset + armW + innerR, y: hInset + armH))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW, y: hInset + armH + innerR),
            control: CGPoint(x: vInset + armW, y: hInset + armH)
        )
        p.addLine(to: CGPoint(x: vInset + armW, y: h - cornerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset + armW - cornerR, y: h),
            control: CGPoint(x: vInset + armW, y: h)
        )
        p.addLine(to: CGPoint(x: vInset + cornerR, y: h))
        p.addQuadCurve(
            to: CGPoint(x: vInset, y: h - cornerR),
            control: CGPoint(x: vInset, y: h)
        )
        p.addLine(to: CGPoint(x: vInset, y: hInset + armH + innerR))
        p.addQuadCurve(
            to: CGPoint(x: vInset - innerR, y: hInset + armH),
            control: CGPoint(x: vInset, y: hInset + armH)
        )
        p.addLine(to: CGPoint(x: cornerR, y: hInset + armH))
        p.addQuadCurve(
            to: CGPoint(x: 0, y: hInset + armH - cornerR),
            control: CGPoint(x: 0, y: hInset + armH)
        )
        p.addLine(to: CGPoint(x: 0, y: hInset + cornerR))
        p.addQuadCurve(
            to: CGPoint(x: cornerR, y: hInset),
            control: CGPoint(x: 0, y: hInset)
        )
        p.addLine(to: CGPoint(x: vInset - innerR, y: hInset))
        p.addQuadCurve(
            to: CGPoint(x: vInset, y: hInset - innerR),
            control: CGPoint(x: vInset, y: hInset)
        )
        p.closeSubpath()
        return p
    }
}

private enum DPadArmGeometry {
    static let innerCornerRatio: CGFloat = 0.5

    static func frame(
        direction: ControlDirection, size: CGFloat, armFraction: CGFloat
    ) -> CGRect {
        let armW = size * armFraction
        let armH = size * armFraction
        let hInset = (size - armH) / 2
        let vInset = (size - armW) / 2
        let armLen = (size - armW) / 2
        switch direction {
        case .up:
            return CGRect(x: vInset, y: 0, width: armW, height: armLen)
        case .down:
            return CGRect(x: vInset, y: size - armLen, width: armW, height: armLen)
        case .left:
            return CGRect(x: 0, y: hInset, width: armLen, height: armH)
        case .right:
            return CGRect(x: size - armLen, y: hInset, width: armLen, height: armH)
        }
    }

    static func cornerRadii(
        direction: ControlDirection, size: CGFloat, armFraction: CGFloat,
        cornerFraction: CGFloat
    ) -> RectangleCornerRadii {
        let armW = size * armFraction
        let outerR = min(armW * cornerFraction, armW / 2)
        let innerR = outerR * innerCornerRatio
        switch direction {
        case .up:
            return RectangleCornerRadii(
                topLeading: outerR, bottomLeading: innerR,
                bottomTrailing: innerR, topTrailing: outerR)
        case .down:
            return RectangleCornerRadii(
                topLeading: innerR, bottomLeading: outerR,
                bottomTrailing: outerR, topTrailing: innerR)
        case .left:
            return RectangleCornerRadii(
                topLeading: outerR, bottomLeading: outerR,
                bottomTrailing: innerR, topTrailing: innerR)
        case .right:
            return RectangleCornerRadii(
                topLeading: innerR, bottomLeading: innerR,
                bottomTrailing: outerR, topTrailing: outerR)
        }
    }
}
