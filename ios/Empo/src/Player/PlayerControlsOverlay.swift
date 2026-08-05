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
  @Binding var editingButton: ButtonModel?
  @Binding var editingActionButton: ActionButtonModel?
  @Binding var editingDPad: Bool
  @Binding var draggingDPad: Bool
  @Binding var draggingButtonID: UUID?

  var body: some View {
    let separatedPositions = layout.separatedDisplayPositions(
      for: geo.size, safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY,
      includeActionButton: { editMode || actions.isAvailable($0.action) })
    ZStack {
      dpadView
      ForEach(Array(layout.buttons.enumerated()), id: \.element.id) { index, button in
        actionButton(button: button, index: index, displayPosition: separatedPositions[button.id])
      }
      ForEach(layout.actionButtons) { button in
        // Unavailable actions (fast forward in a game with no
        // multiplier) hide during play. Edit mode keeps them
        // visible with a badge so they can move or delete.
        if editMode || actions.isAvailable(button.action) {
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
      safeArea: AppWindow.currentSafeArea, controlsMinY: controlsMinY)
    let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
    DPad(size: size, editing: editMode)
      .frame(width: size, height: size)
      // Measure the region BEFORE .position: position()
      // expands to the full proposed space, so a region attached
      // after it would cover the whole screen.
      .chromeHitRegion("controls.dpad")
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

  private var dpadDragGesture: some Gesture {
    DragGesture()
      .onChanged { value in
        if !draggingDPad {
          layout.recordEditSnapshot()
          draggingDPad = true
        }
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
  private func actionButton(button: ButtonModel, index: Int, displayPosition: CGPoint?) -> some View
  {
    // displayPosition is already absolute and separation-adjusted
    // (post-clamp). The fallback only covers the empty-layout case.
    let pos =
      displayPosition
      ?? ControlsZone.absolutePosition(
        for: button.relativeCenter, in: geo.size,
        controlSize: CGSize(width: button.size, height: button.size),
        safeArea: AppWindow.currentSafeArea,
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
    .chromeHitRegion("controls.button.\(button.id.uuidString)")
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
        safeArea: AppWindow.currentSafeArea,
        controlsMinY: controlsMinY)
    let isDragging = draggingButtonID == button.id
    let anchor = UnitPoint(x: pos.x / geo.size.width, y: pos.y / geo.size.height)
    let unavailable = !actions.isAvailable(button.action)
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
    .chromeHitRegion("controls.actionButton.\(button.id.uuidString)")
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

  private func actionButtonDragGesture(id: UUID, size: CGFloat) -> some Gesture {
    DragGesture()
      .onChanged { value in
        if draggingButtonID != id {
          layout.recordEditSnapshot()
          draggingButtonID = id
        }
        let clamped = ControlsZone.clampToSafeArea(
          value.location, controlSize: size, geoSize: geo.size, safeArea: AppWindow.currentSafeArea,
          controlsMinY: controlsMinY)
        layout.updateActionButton(
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

  private func buttonDragGesture(id: UUID, size: CGFloat) -> some Gesture {
    DragGesture()
      .onChanged { value in
        if draggingButtonID != id {
          layout.recordEditSnapshot()
          draggingButtonID = id
        }
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
