// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// D-pad + action buttons layer. Rendering, drag gestures, and edit
/// affordances (tap-to-edit, delete chip, drag scale) live here so
/// PlayerView only has to toggle visibility and own the edit state
/// that the edit dialogs consume.

struct PlayerControlsOverlay: View {
    @Bindable var layout: ControlsLayout
    var actions: PlayerActionRegistry
    let geo: GeometryProxy
    let controlsMinY: CGFloat
    let editMode: Bool
    /// Injected so the profile editor can fake per-orientation
    /// insets. The player passes the live window value.
    let safeArea: EdgeInsets
    /// The out-of-player editor: every action renders as
    /// available and no hit regions are published.
    var isPreview = false
    @Binding var editDialog: ControlsEditDialog?

    /// The control that owns the drag in flight: `dpadDragKey` or a
    /// button ID. A second finger on another control waits until it
    /// ends.
    @State private var dragOwner: AnyHashable?
    private static let dpadDragKey: AnyHashable = "dpad"
    private var draggingDPad: Bool { dragOwner == Self.dpadDragKey }

    /// Edit-mode drag snapping. Shared with the edit toolbar's
    /// toggle through UserDefaults, so both surfaces stay in sync.
    @AppStorage(DefaultsKey.controlsEditSnapToGrid) private var snapToGrid = false

    var body: some View {
        let separatedPositions = layout.separatedDisplayPositions(
            for: geo.size, safeArea: safeArea, controlsMinY: controlsMinY,
            // The separation pass stays off ONLY while a CONTROL
            // drags (neighbors must not move under the finger, the
            // rigid collision owns that case). Everywhere else it
            // runs, so a crushed zone rearranges its controls
            // instead of clamping them into a stack.
            separate: dragOwner == nil,
            includeActionButton: { isPreview || editMode || actions.isAvailable($0.action) })
        ZStack {
            editGridOverlay
            dpadView
            ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, button in
                actionButton(button: button, index: index, displayPosition: separatedPositions[button.id])
            }
            ForEach(layout.actionButtons) { button in
                // Unavailable actions (fast forward in a game with no
                // multiplier) hide during play. Edit mode keeps them
                // visible with a badge so they can move or delete.
                if isPreview || editMode || actions.isAvailable(button.action) {
                    functionButton(button: button, displayPosition: separatedPositions[button.id])
                }
            }
        }
        // The add flow solves spawn placement against this canvas,
        // so a fresh control cannot land under the chrome. One
        // onChange on the value itself covers appear + every input
        // that can move the lattice (canvas size, safe area, zone).
        .onChange(
            of: ControlsLayout.EditGeometry(
                geoSize: geo.size, safeArea: safeArea,
                controlsMinY: controlsMinY),
            initial: true
        ) { _, geometry in
            layout.editGeometry = geometry
        }
    }

    /// The snap lattice, drawn only while edit mode and the toggle
    /// are both on. Anchored at the zone's top-left, the same origin
    /// snappedToEditGrid rounds against, so every line is a legal
    /// snap line. Under the controls, never hit-testable.
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

    @ViewBuilder
    private var dpadView: some View {
        let size = layout.dpadSize
        let pos = ControlsZone.absolutePosition(
            for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size),
            safeArea: safeArea, controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
        movementControl(size: size)
            .frame(width: size, height: size)
            // Measure the region BEFORE .position: position()
            // expands to the full proposed space, so a region attached
            // after it would cover the whole screen.
            .chromeHitRegion("controls.dpad", enabled: !isPreview)
            .opacity(layout.dpadOpacity)
            .scaleEffect(draggingDPad ? ControlsZone.dragScaleFactor : 1.0)
            .animation(Motion.snappy, value: draggingDPad)
            .position(pos)
            .transition(.controlAppear(anchor: anchor))
            // Tap-to-edit and drag-to-reposition are edit-mode
            // affordances, so mask them out entirely during play.
            // An always-live tap recognizer here (even one whose
            // action no-ops) forces SwiftUI's tap-vs-drag
            // disambiguation onto every touch aimed at the control
            // below, deferring its touch-down until the finger moves
            // or lifts. `.subviews` (not `.none`, which also disables
            // the subview hierarchy's gestures) keeps the control's
            // own input path untouched.
            .gesture(
                TapGesture().onEnded { editDialog = .dpad },
                including: editMode ? .all : .subviews
            )
            .editDrag(
                including: editMode ? .all : .subviews,
                onChanged: { value in
                    guard claimDrag(Self.dpadDragKey) else { return }
                    let resolved = resolvedDragPosition(
                        value.location, draggedID: nil, draggedIsDPad: true,
                        size: layout.dpadSize)
                    layout.dpadRelativeCenter = CGPoint(
                        x: resolved.x / geo.size.width,
                        y: resolved.y / geo.size.height
                    )
                },
                onFinished: { finishDrag(Self.dpadDragKey) })
    }

    /// The movement control renders per style. Everything around it
    /// (position, drag, edit gestures, hit region) is shared.
    @ViewBuilder
    private func movementControl(size: CGFloat) -> some View {
        switch layout.dpadStyle {
        case .dpad:
            DPad(size: size, editing: editMode)
        case .stick:
            Joystick(size: size, editing: editMode)
        }
    }

    /// The first control to move owns the drag and records the undo
    /// step. Returns false for every other control.
    private func claimDrag(_ key: AnyHashable) -> Bool {
        if dragOwner == nil {
            layout.recordEditSnapshot()
            dragOwner = key
            lastDragResolved = nil
        }
        return dragOwner == key
    }

    private func finishDrag(_ key: AnyHashable) {
        guard dragOwner == key else { return }
        dragOwner = nil
        lastDragResolved = nil
        layout.save()
    }

    @ViewBuilder
    private func actionButton(button: ButtonModel, index: Int, displayPosition: CGPoint?) -> some View {
        editableControl(
            ActionButton(
                id: button.id,
                label: button.label,
                scancode: button.scancode,
                size: button.size,
                editing: editMode
            ),
            id: button.id,
            size: button.size,
            opacity: button.opacity,
            position: resolvedPosition(
                displayPosition, center: button.relativeCenter, size: button.size),
            hitRegionKey: "controls.button.\(button.id.uuidString)",
            onTapEdit: { editDialog = .button(button.id) },
            onDelete: { layout.removeButton(id: button.id) },
            update: { layout.updateButton(id: button.id, relativeCenter: $0) }
        )
    }

    @ViewBuilder
    private func functionButton(button: ActionButtonModel, displayPosition: CGPoint?) -> some View {
        // The loader skips unknown actions (W004) and the picker only
        // offers catalog entries, so the lookup always succeeds.
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
            id: button.id,
            size: button.size,
            opacity: button.opacity,
            position: resolvedPosition(
                displayPosition, center: button.relativeCenter, size: button.size),
            hitRegionKey: "controls.actionButton.\(button.id.uuidString)",
            onTapEdit: { editDialog = .actionButton(button.id) },
            onDelete: { layout.removeActionButton(id: button.id) },
            update: { layout.updateActionButton(id: button.id, relativeCenter: $0) }
        )
    }

    /// Last resolved center of the drag in flight. The collision
    /// solve uses it as side memory (no tunneling through an
    /// obstacle's center), and the clamp+collide loop keeps a control
    /// squeezed between a wall and a neighbor on its own side instead
    /// of re-clamping into overlap.
    @State private var lastDragResolved: CGPoint?

    /// The dragged control's stored center in absolute space. The
    /// side memory seeds from it so the drag's FIRST event already
    /// knows its approach side.
    private func currentAbsoluteCenter(
        draggedID: UUID?, draggedIsDPad: Bool
    ) -> CGPoint? {
        let relative: CGPoint
        let size: CGFloat
        if draggedIsDPad {
            relative = layout.dpadRelativeCenter
            size = layout.dpadSize
        } else if let button = layout.buttons.first(where: { $0.id == draggedID }) {
            relative = button.relativeCenter
            size = button.size
        } else if let button = layout.actionButtons.first(where: { $0.id == draggedID }) {
            relative = button.relativeCenter
            size = button.size
        } else {
            return nil
        }
        return ControlsZone.absolutePosition(
            for: relative, in: geo.size, controlSize: CGSize(width: size, height: size),
            safeArea: safeArea, controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
    }

    /// Shared drag pipeline: alternate the zone clamp and the rigid
    /// collision until stable. Either alone can undo the other at
    /// the zone edges. An update that STILL collides after the
    /// solve (no free space on the approach side) is rejected: the
    /// control holds its last valid position instead of entering
    /// the obstacle.
    private func resolvedDragPosition(
        _ location: CGPoint, draggedID: UUID?, draggedIsDPad: Bool, size: CGFloat
    ) -> CGPoint {
        if lastDragResolved == nil {
            lastDragResolved = currentAbsoluteCenter(
                draggedID: draggedID, draggedIsDPad: draggedIsDPad)
        }
        // Snap BEFORE the solve, so clamp and collision run against
        // on-grid targets. The solve may still leave the control
        // off-grid at a wall or against a neighbor; a valid position
        // beats an exact one.
        let target =
            snapToGrid
            ? ControlsZone.snappedToEditGrid(
                location, controlSize: size, geoSize: geo.size,
                safeArea: safeArea, controlsMinY: controlsMinY)
            : location
        var center = ControlsZone.clampToSafeArea(
            target, controlSize: size, geoSize: geo.size, safeArea: safeArea,
            controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
        for _ in 0..<3 {
            center = layout.collisionResolvedCenter(
                center, previous: lastDragResolved, draggedID: draggedID,
                draggedIsDPad: draggedIsDPad,
                controlSize: size, geoSize: geo.size, safeArea: safeArea,
                controlsMinY: controlsMinY)
            center = ControlsZone.clampToSafeArea(
                center, controlSize: size, geoSize: geo.size, safeArea: safeArea,
                controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
        }
        if layout.dragPositionCollides(
            center, draggedID: draggedID, draggedIsDPad: draggedIsDPad,
            controlSize: size, geoSize: geo.size, safeArea: safeArea,
            controlsMinY: controlsMinY),
            let held = lastDragResolved
        {
            return held
        }
        lastDragResolved = center
        return center
    }

    /// displayPosition is already absolute and separation-adjusted
    /// (post-clamp). The fallback only covers the empty-layout case.
    private func resolvedPosition(
        _ displayPosition: CGPoint?, center: CGPoint, size: CGFloat
    ) -> CGPoint {
        displayPosition
            ?? ControlsZone.absolutePosition(
                for: center, in: geo.size,
                controlSize: CGSize(width: size, height: size),
                safeArea: safeArea,
                controlsMinY: controlsMinY, keepout: layout.toolbarKeepout)
    }

    /// The edit chrome every draggable button shares: tap-to-edit,
    /// delete chip, hit region, drag scale, appear transition, and
    /// ONE drag gesture whose `update` closure routes to the right
    /// mutator. Key buttons and action buttons cannot drift apart.
    private func editableControl<Control: View>(
        _ control: Control,
        id: UUID,
        size: CGFloat,
        opacity: Double,
        position: CGPoint,
        hitRegionKey: String,
        onTapEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        update: @escaping (CGPoint) -> Void
    ) -> some View {
        let isDragging = dragOwner == AnyHashable(id)
        let anchor = UnitPoint(
            x: position.x / geo.size.width, y: position.y / geo.size.height)
        return
            control
            .frame(width: size, height: size)
            .opacity(opacity)
            // Edit-mode-only, same masking rationale as the D-pad's
            // tap-to-edit gesture above.
            .gesture(
                TapGesture().onEnded { onTapEdit() },
                including: editMode ? .all : .subviews
            )
            .overlay(alignment: .topTrailing) {
                if editMode && !isDragging {
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
            .chromeHitRegion(hitRegionKey, enabled: !isPreview)
            .scaleEffect(isDragging ? ControlsZone.dragScaleFactor : 1.0)
            .animation(Motion.snappy, value: isDragging)
            .position(position)
            .transition(.controlAppear(anchor: anchor))
            .editDrag(
                including: editMode ? .all : .subviews,
                onChanged: { value in
                    guard claimDrag(id) else { return }
                    let resolved = resolvedDragPosition(
                        value.location, draggedID: id, draggedIsDPad: false, size: size)
                    update(
                        CGPoint(
                            x: resolved.x / geo.size.width,
                            y: resolved.y / geo.size.height
                        ))
                },
                onFinished: { finishDrag(id) }
            )
            // An undo can remove the control mid-drag. Its gesture
            // then never ends, so the drag must end here.
            .onDisappear { finishDrag(id) }
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
