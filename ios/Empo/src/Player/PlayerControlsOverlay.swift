// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

struct PlayerControlsOverlay: View {
    @Bindable var layout: ControlsLayout
    var actions: PlayerActionRegistry
    let geo: GeometryProxy
    let controlsMinY: CGFloat
    let editMode: Bool
    /// The profile editor gives the insets of each orientation.
    let safeArea: EdgeInsets
    /// The profile editor: each action shows as available, and the
    /// controls publish no hit regions.
    var isPreview = false
    @Binding var editDialog: ControlsEditDialog?
    let keys: HeldKeys<KeyHolder>

    /// A second finger on another control waits until the drag ends.
    @State private var dragOwner: EditDragSubject?
    /// The collision solve uses the last center as side memory, so a
    /// control cannot go through the center of an obstacle.
    @State private var lastDragResolved: CGPoint?

    @AppStorage(DefaultsKey.controlsEditSnapToGrid) private var snapToGrid = false

    var body: some View {
        let separatedPositions = layout.separatedDisplayPositions(
            for: geo.size, safeArea: safeArea, controlsMinY: controlsMinY,
            // During a drag, the neighbors must not move under the
            // finger. Then the collision solve keeps the controls apart.
            separate: dragOwner == nil,
            includeActionButton: { showsActionButton($0.action) })
        ZStack {
            editGridOverlay
            dpadView
            ForEach(layout.buttons) { button in
                actionButton(button: button, displayPosition: separatedPositions[button.id])
            }
            ForEach(layout.actionButtons) { button in
                if showsActionButton(button.action) {
                    functionButton(button: button, displayPosition: separatedPositions[button.id])
                }
            }
        }
        // The add flow places a new control against this canvas, so it
        // cannot go under the chrome.
        .onChange(of: editGeometry, initial: true) { _, geometry in
            layout.editGeometry = geometry
        }
    }

    /// An unavailable action, such as fast forward in a game with no
    /// multiplier, hides during play. Edit mode shows it with a badge,
    /// so the user can move or delete it.
    private func showsActionButton(_ action: String) -> Bool {
        isPreview || editMode || actions.isAvailable(action)
    }

    private var editGeometry: ControlsLayout.EditGeometry {
        ControlsLayout.EditGeometry(geoSize: geo.size, safeArea: safeArea, controlsMinY: controlsMinY)
    }

    /// The lines start at the top-left corner of the zone, the origin
    /// of `snappedToEditGrid`.
    @ViewBuilder
    private var editGridOverlay: some View {
        if editMode && snapToGrid {
            let zone = ControlsZone.bounds(
                controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geo.size)
            Canvas { context, _ in
                var lines = Path()
                var x = zone.minX
                while x <= zone.maxX {
                    lines.move(to: CGPoint(x: x, y: zone.minY))
                    lines.addLine(to: CGPoint(x: x, y: zone.maxY))
                    x += ControlsZone.editGridStep
                }
                var y = zone.minY
                while y <= zone.maxY {
                    lines.move(to: CGPoint(x: zone.minX, y: y))
                    lines.addLine(to: CGPoint(x: zone.maxX, y: y))
                    y += ControlsZone.editGridStep
                }
                context.stroke(
                    lines, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var dpadView: some View {
        let size = layout.dpadSize
        return editableControl(
            movementControl(size: size),
            subject: .dpad,
            size: size,
            opacity: layout.dpadOpacity,
            position: ControlsZone.absolutePosition(
                for: layout.dpadRelativeCenter, in: geo.size, controlSize: size,
                safeArea: safeArea, controlsMinY: controlsMinY, keepout: layout.toolbarKeepout),
            onTapEdit: { editDialog = .dpad },
            onDelete: nil,
            update: { layout.dpadRelativeCenter = $0 }
        )
    }

    @ViewBuilder
    private func movementControl(size: CGFloat) -> some View {
        switch layout.dpadStyle {
        case .dpad:
            DPad(size: size, editing: editMode, onDirection: sendDirection)
        case .stick:
            Joystick(size: size, editing: editMode, onDirection: sendDirection)
        }
    }

    private func sendDirection(_ direction: ControlDirection, pressed: Bool) {
        send(direction.scancode, pressed: pressed, by: .touch("dpad:\(direction)"))
    }

    private func send(_ scancode: Int32, pressed: Bool, by holder: KeyHolder) {
        if pressed {
            keys.hold(scancode, by: holder)
        } else {
            keys.release(scancode, by: holder)
        }
    }

    /// The first control to move owns the drag and records the undo
    /// step. Returns false for every other control.
    private func claimDrag(_ key: EditDragSubject) -> Bool {
        if dragOwner == nil {
            layout.recordEditSnapshot()
            dragOwner = key
            lastDragResolved = nil
        }
        return dragOwner == key
    }

    private func finishDrag(_ key: EditDragSubject) {
        guard dragOwner == key else { return }
        dragOwner = nil
        lastDragResolved = nil
        try? layout.save()
    }

    @ViewBuilder
    private func actionButton(button: ButtonModel, displayPosition: CGPoint?) -> some View {
        editableControl(
            ActionButton(
                label: button.label,
                size: button.size,
                editing: editMode,
                onPress: { send(button.scancode, pressed: true, by: .touch("button:\(button.id)")) },
                onRelease: { send(button.scancode, pressed: false, by: .touch("button:\(button.id)")) }
            ),
            subject: .control(button.id),
            size: button.size,
            opacity: button.opacity,
            position: resolvedPosition(
                displayPosition, center: button.relativeCenter, size: button.size),
            onTapEdit: { editDialog = .button(button.id) },
            onDelete: { layout.removeButton(id: button.id) },
            update: { layout.updateButton(id: button.id, relativeCenter: $0) }
        )
    }

    @ViewBuilder
    private func functionButton(button: ActionButtonModel, displayPosition: CGPoint?) -> some View {
        // The loader skips unknown actions, and the picker shows only
        // catalog entries.
        if let action = EmpoActionCatalog.action(id: button.action) {
            functionButton(button: button, action: action, displayPosition: displayPosition)
        }
    }

    @ViewBuilder
    private func functionButton(
        button: ActionButtonModel, action: EmpoAction, displayPosition: CGPoint?
    ) -> some View {
        editableControl(
            FunctionButton(
                action: action,
                size: button.size,
                editing: editMode,
                isActive: actions.isToggleActive(action),
                onPress: { actions.handle(button.action, pressed: true) },
                onRelease: { actions.handle(button.action, pressed: false) }
            )
            .overlay(alignment: .bottom) {
                if editMode && !isPreview && !actions.isAvailable(button.action) {
                    Text(BindingsCatalog.unavailableActionNote(button.action, in: .editModeBadge))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .fixedSize()
                        .offset(y: 14)
                        .allowsHitTesting(false)
                }
            },
            subject: .control(button.id),
            size: button.size,
            opacity: button.opacity,
            position: resolvedPosition(
                displayPosition, center: button.relativeCenter, size: button.size),
            onTapEdit: { editDialog = .actionButton(button.id) },
            onDelete: { layout.removeActionButton(id: button.id) },
            update: { layout.updateActionButton(id: button.id, relativeCenter: $0) }
        )
    }

    private func resolvedDragPosition(
        _ location: CGPoint, subject: EditDragSubject, size: CGFloat
    ) -> CGPoint {
        if lastDragResolved == nil {
            lastDragResolved = layout.absoluteCenter(of: subject, in: editGeometry)
        }
        let center = layout.resolvedDragCenter(
            location, previous: lastDragResolved, subject: subject, size: size, in: editGeometry)
        lastDragResolved = center
        return center
    }

    /// The fallback is for an empty layout.
    private func resolvedPosition(
        _ displayPosition: CGPoint?, center: CGPoint, size: CGFloat
    ) -> CGPoint {
        displayPosition
            ?? ControlsZone.absolutePosition(
                for: center, in: geo.size,
                controlSize: size,
                safeArea: safeArea,
                controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
    }

    private func editableControl<Control: View>(
        _ control: Control,
        subject: EditDragSubject,
        size: CGFloat,
        opacity: Double,
        position: CGPoint,
        onTapEdit: @escaping () -> Void,
        onDelete: (() -> Void)?,
        update: @escaping (CGPoint) -> Void
    ) -> some View {
        let isDragging = dragOwner == subject
        let anchor = UnitPoint(
            x: position.x / geo.size.width, y: position.y / geo.size.height)
        return
            control
            .frame(width: size, height: size)
            .opacity(opacity)
            // A live tap recognizer, also one that does nothing, makes
            // SwiftUI wait to tell a tap from a drag on each touch. The
            // control then gets its touch-down only when the finger
            // moves or lifts. `.subviews` keeps the input of the
            // control. `.none` also turns off the gestures of the
            // subviews.
            .gesture(
                TapGesture().onEnded { onTapEdit() },
                including: editMode ? .all : .subviews
            )
            .overlay(alignment: .topTrailing) {
                if editMode && !isDragging, let onDelete {
                    Button {
                        withAnimation(Motion.snappy) {
                            onDelete()
                        }
                    } label: {
                        Chip(systemImage: "xmark", tint: .destructive)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // `.position` fills the full proposed space, so a region
            // measured after it covers the whole screen.
            .chromeHitRegion(enabled: !isPreview)
            .scaleEffect(isDragging ? ControlsZone.dragScaleFactor : 1.0)
            .animation(Motion.snappy, value: isDragging)
            .position(position)
            .transition(.controlAppear(anchor: anchor))
            .editDrag(
                including: editMode ? .all : .subviews,
                onChanged: { value in
                    guard claimDrag(subject) else { return }
                    let resolved = resolvedDragPosition(value.location, subject: subject, size: size)
                    update(
                        CGPoint(
                            x: resolved.x / geo.size.width,
                            y: resolved.y / geo.size.height
                        ))
                },
                onFinished: { finishDrag(subject) }
            )
            // An undo can remove the control during a drag. Its gesture
            // then does not end, so the drag ends here.
            .onDisappear { finishDrag(subject) }
    }
}

extension View {
    /// A drag that reports its end also when the system cancels it.
    /// A cancel skips `onEnded`, but it resets the gesture state.
    func editDrag(
        minimumDistance: CGFloat = 10,
        including mask: GestureMask = .all,
        onChanged: @escaping (DragGesture.Value) -> Void,
        onFinished: @escaping () -> Void
    ) -> some View {
        modifier(
            EditDragModifier(
                minimumDistance: minimumDistance, mask: mask,
                onChanged: onChanged, onFinished: onFinished))
    }
}

private struct EditDragModifier: ViewModifier {
    let minimumDistance: CGFloat
    let mask: GestureMask
    let onChanged: (DragGesture.Value) -> Void
    let onFinished: () -> Void

    @GestureState private var active = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: minimumDistance)
                    .updating($active) { _, state, _ in state = true }
                    .onChanged(onChanged),
                including: mask
            )
            .onChange(of: active) { _, isActive in
                if !isActive { onFinished() }
            }
    }
}
