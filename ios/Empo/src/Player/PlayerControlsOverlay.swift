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
    /// insets; the player passes the live window value.
    let safeArea: EdgeInsets
    /// The out-of-player editor: every action renders as
    /// available and no hit regions are published.
    var isPreview = false
    @Binding var editingButton: ButtonModel?
    @Binding var editingActionButton: ActionButtonModel?
    @Binding var editingDPad: Bool
    @Binding var draggingDPad: Bool
    @Binding var draggingButtonID: UUID?

    var body: some View {
        let separatedPositions = layout.separatedDisplayPositions(
            for: geo.size, safeArea: safeArea, controlsMinY: controlsMinY,
            // The separation pass stays off ONLY while a CONTROL
            // drags (neighbors must not move under the finger; the
            // rigid collision owns that case). Everywhere else it
            // runs, so a crushed zone rearranges its controls
            // instead of clamping them into a stack.
            separate: draggingButtonID == nil && !draggingDPad,
            includeActionButton: { isPreview || editMode || actions.isAvailable($0.action) })
        ZStack {
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
    }

    @ViewBuilder
    private var dpadView: some View {
        let size = layout.dpadSize
        let pos = ControlsZone.absolutePosition(
            for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size),
            safeArea: safeArea, controlsMinY: controlsMinY)
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
                TapGesture().onEnded { editingDPad = true },
                including: editMode ? .all : .subviews
            )
            .gesture(dpadDragGesture, including: editMode ? .all : .subviews)
    }

    /// The movement control renders per style; everything around it
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

    private var dpadDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !draggingDPad {
                    layout.recordEditSnapshot()
                    draggingDPad = true
                    lastDragResolved = nil
                }
                let resolved = resolvedDragPosition(
                    value.location, draggedID: nil, draggedIsDPad: true,
                    size: layout.dpadSize)
                layout.dpadRelativeCenter = CGPoint(
                    x: resolved.x / geo.size.width,
                    y: resolved.y / geo.size.height
                )
            }
            .onEnded { _ in
                draggingDPad = false
                lastDragResolved = nil
                layout.save()
            }
    }

    @ViewBuilder
    private func actionButton(button: ButtonModel, index: Int, displayPosition: CGPoint?) -> some View {
        // displayPosition is already absolute and separation-adjusted
        // (post-clamp). The fallback only covers the empty-layout case.
        let pos =
            displayPosition
            ?? ControlsZone.absolutePosition(
                for: button.relativeCenter, in: geo.size,
                controlSize: CGSize(width: button.size, height: button.size),
                safeArea: safeArea,
                controlsMinY: controlsMinY)
        let isDragging = draggingButtonID == button.id
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
        ActionButton(
            label: button.label,
            scancode: button.scancode,
            size: button.size,
            editing: editMode
        )
        .frame(width: button.size, height: button.size)
        .opacity(button.opacity)
        // Edit-mode-only, same masking rationale as the D-pad's
        // tap-to-edit gesture above.
        .gesture(
            TapGesture().onEnded { editingButton = button },
            including: editMode ? .all : .subviews
        )
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
        .chromeHitRegion("controls.button.\(button.id.uuidString)", enabled: !isPreview)
        .scaleEffect(isDragging ? ControlsZone.dragScaleFactor : 1.0)
        .animation(Motion.snappy, value: isDragging)
        .position(pos)
        .transition(.controlAppear(anchor: anchor))
        .gesture(
            buttonDragGesture(id: button.id, size: button.size),
            including: editMode ? .all : .subviews)
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
        let pos =
            displayPosition
            ?? ControlsZone.absolutePosition(
                for: button.relativeCenter, in: geo.size,
                controlSize: CGSize(width: button.size, height: button.size),
                safeArea: safeArea,
                controlsMinY: controlsMinY)
        let isDragging = draggingButtonID == button.id
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
        let unavailable = !isPreview && !actions.isAvailable(button.action)
        FunctionButton(
            action: action,
            size: button.size,
            editing: editMode,
            isActive: isToggleActive(action),
            onPress: { actions.handle(button.action, pressed: true) },
            onRelease: { actions.handle(button.action, pressed: false) }
        )
        .frame(width: button.size, height: button.size)
        .opacity(button.opacity)
        .gesture(
            TapGesture().onEnded { editingActionButton = button },
            including: editMode ? .all : .subviews
        )
        .overlay(alignment: .topTrailing) {
            if editMode && !isDragging {
                Button {
                    withAnimation(Motion.snappy) {
                        layout.removeActionButton(id: button.id)
                    }
                } label: {
                    Chip(systemImage: "xmark", tint: .destructive)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if editMode && unavailable {
                Text("Unavailable in this game")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .fixedSize()
                    .offset(y: 14)
                    .allowsHitTesting(false)
            }
        }
        .chromeHitRegion("controls.actionButton.\(button.id.uuidString)", enabled: !isPreview)
        .scaleEffect(isDragging ? ControlsZone.dragScaleFactor : 1.0)
        .animation(Motion.snappy, value: isDragging)
        .position(pos)
        .transition(.controlAppear(anchor: anchor))
        .gesture(
            actionButtonDragGesture(id: button.id, size: button.size),
            including: editMode ? .all : .subviews)
    }

    /// A latched fast-forward toggle shows its engaged state on the
    /// button face.
    private func isToggleActive(_ action: EmpoAction) -> Bool {
        guard action.kind == .toggle else { return false }
        switch action.id {
        case EmpoActionCatalog.fastForwardToggle:
            return actions.runtime.fastForwardActive
        case EmpoActionCatalog.toggleCheats:
            return actions.runtime.cheatsEnabled
        default:
            return false
        }
    }

    /// Last resolved center of the drag in flight. The collision
    /// solve uses it as side memory (no tunneling through an
    /// obstacle's center), and the clamp+collide loop keeps a
    /// control squeezed between a wall and a neighbor on its own
    /// side instead of re-clamping into overlap.
    @State private var lastDragResolved: CGPoint?

    /// The dragged control's stored center in absolute space; the
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
            safeArea: safeArea, controlsMinY: controlsMinY)
    }

    /// Shared drag pipeline: alternate the zone clamp and the rigid
    /// collision until stable — either alone can undo the other at
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
        var center = ControlsZone.clampToSafeArea(
            location, controlSize: size, geoSize: geo.size, safeArea: safeArea,
            controlsMinY: controlsMinY)
        for _ in 0..<3 {
            center = layout.collisionResolvedCenter(
                center, previous: lastDragResolved, draggedID: draggedID,
                draggedIsDPad: draggedIsDPad,
                controlSize: size, geoSize: geo.size, safeArea: safeArea,
                controlsMinY: controlsMinY)
            center = ControlsZone.clampToSafeArea(
                center, controlSize: size, geoSize: geo.size, safeArea: safeArea,
                controlsMinY: controlsMinY)
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

    private func actionButtonDragGesture(id: UUID, size: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if draggingButtonID != id {
                    layout.recordEditSnapshot()
                    draggingButtonID = id
                    lastDragResolved = nil
                }
                let resolved = resolvedDragPosition(
                    value.location, draggedID: id, draggedIsDPad: false, size: size)
                layout.updateActionButton(
                    id: id,
                    relativeCenter: CGPoint(
                        x: resolved.x / geo.size.width,
                        y: resolved.y / geo.size.height
                    ))
            }
            .onEnded { _ in
                draggingButtonID = nil
                lastDragResolved = nil
                layout.save()
            }
    }

    private func buttonDragGesture(id: UUID, size: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if draggingButtonID != id {
                    layout.recordEditSnapshot()
                    draggingButtonID = id
                    lastDragResolved = nil
                }
                let resolved = resolvedDragPosition(
                    value.location, draggedID: id, draggedIsDPad: false, size: size)
                layout.updateButton(
                    id: id,
                    relativeCenter: CGPoint(
                        x: resolved.x / geo.size.width,
                        y: resolved.y / geo.size.height
                    ))
            }
            .onEnded { _ in
                draggingButtonID = nil
                lastDragResolved = nil
                layout.save()
            }
    }
}
