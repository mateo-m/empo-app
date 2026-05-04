import SwiftUI

/// D-pad + action buttons layer. Rendering, drag gestures, and edit
/// affordances (tap-to-edit, delete chip, drag scale) live here so
/// PlayerView only has to toggle visibility and own the edit state
/// that the edit dialogs consume.

struct PlayerControlsOverlay: View {
    @Bindable var layout: ControlsLayout
    let geo: GeometryProxy
    let controlsMinY: CGFloat
    let editMode: Bool
    @Binding var editingButton: ButtonModel?
    @Binding var editingDPad: Bool
    @Binding var draggingDPad: Bool
    @Binding var draggingButtonID: UUID?

    var body: some View {
        ZStack {
            dpadView
            ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, button in
                actionButton(button: button, index: index)
            }
        }
    }

    @ViewBuilder
    private var dpadView: some View {
        let size = layout.dpadSize
        let pos = ControlsZone.absolutePosition(
            for: layout.dpadRelativeCenter, in: geo.size, controlSize: CGSize(width: size, height: size),
            safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY)
        let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
        DPad(size: size, editing: editMode)
            .frame(width: size, height: size)
            .opacity(layout.dpadOpacity)
            .scaleEffect(draggingDPad ? ControlsZone.dragScaleFactor : 1.0)
            .animation(Motion.snappy, value: draggingDPad)
            .position(pos)
            .transition(.controlAppear(anchor: anchor))
            // Tap-to-edit only fires in edit mode. Tapping the D-pad
            // during normal play falls through to the DPad's own
            // gesture for direction input.
            .onTapGesture {
                guard editMode else { return }
                editingDPad = true
            }
            .gesture(dpadDragGesture, including: editMode ? .all : .none)
    }

    private var dpadDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !draggingDPad { draggingDPad = true }
                let clamped = ControlsZone.clampToSafeArea(
                    value.location, controlSize: layout.dpadSize, geoSize: geo.size,
                    safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY)
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
    private func actionButton(button: ButtonModel, index: Int) -> some View {
        let pos = ControlsZone.absolutePosition(
            for: button.relativeCenter, in: geo.size,
            controlSize: CGSize(width: button.size, height: button.size), safeArea: AppWindow.currentSafeArea,
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
        .scaleEffect(isDragging ? ControlsZone.dragScaleFactor : 1.0)
        .animation(Motion.snappy, value: isDragging)
        .position(pos)
        .transition(.controlAppear(anchor: anchor))
        .gesture(buttonDragGesture(id: button.id, size: button.size), including: editMode ? .all : .none)
    }

    private func buttonDragGesture(id: UUID, size: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if draggingButtonID != id { draggingButtonID = id }
                let clamped = ControlsZone.clampToSafeArea(
                    value.location, controlSize: size, geoSize: geo.size, safeArea: AppWindow.currentSafeArea,
                    controlsMinY: controlsMinY)
                layout.updateButton(
                    id: id,
                    relativeCenter: CGPoint(
                        x: clamped.x / geo.size.width,
                        y: clamped.y / geo.size.height
                    ))
            }
            .onEnded { _ in
                draggingButtonID = nil
                layout.save()
            }
    }
}
