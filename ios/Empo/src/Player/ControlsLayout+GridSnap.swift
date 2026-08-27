import SwiftUI

/// Grid snap for the controls edit mode, split out of
/// ControlsLayout.swift: rounding every control onto the lattice,
/// plus the spawn solve that places freshly added controls through
/// the same clamp + collision + chrome-wall pipeline a drag gets.
/// The stored state backing this (restore records, the active flag,
/// the last-published canvas geometry) lives in the main file,
/// because extensions cannot add stored properties.
extension ControlsLayout {
    /// The canvas geometry an edit surface renders with.
    struct EditGeometry: Equatable {
        var geoSize: CGSize
        var safeArea: EdgeInsets
        var controlsMinY: CGFloat
    }

    /// Size a freshly added control gets: the default preset,
    /// snapped to the grid step while grid mode is on.
    var newControlSize: CGFloat {
        gridSnapActive ? Self.gridSnappedSize(56) : 56
    }

    /// Rounds every active-orientation control's size to a multiple
    /// of the grid step and its center onto the lattice. Records the
    /// old values first, so untoggling before Done can put them back
    /// exactly. A second call while already applied does nothing.
    func applyGridSnap(geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat) {
        guard !gridSnapActive else { return }
        func snappedCenter(_ relative: CGPoint, size: CGFloat) -> CGPoint {
            let absolute = ControlsZone.absolutePosition(
                for: relative, in: geoSize,
                controlSize: CGSize(width: size, height: size),
                safeArea: safeArea, controlsMinY: controlsMinY)
            let snapped = ControlsZone.snappedToEditGrid(
                absolute, controlSize: size, geoSize: geoSize,
                safeArea: safeArea, controlsMinY: controlsMinY)
            return CGPoint(x: snapped.x / geoSize.width, y: snapped.y / geoSize.height)
        }

        var buttons = self.buttons
        for index in buttons.indices {
            gridSnapOriginals[buttons[index].id] = GridSnapOriginal(
                size: buttons[index].size,
                relativeCenter: buttons[index].relativeCenter)
            let size = Self.gridSnappedSize(buttons[index].size)
            buttons[index].relativeCenter = snappedCenter(
                buttons[index].relativeCenter, size: size)
            buttons[index].size = size
        }
        self.buttons = buttons

        var actionButtons = self.actionButtons
        for index in actionButtons.indices {
            gridSnapOriginals[actionButtons[index].id] = GridSnapOriginal(
                size: actionButtons[index].size,
                relativeCenter: actionButtons[index].relativeCenter)
            let size = Self.gridSnappedSize(actionButtons[index].size)
            actionButtons[index].relativeCenter = snappedCenter(
                actionButtons[index].relativeCenter, size: size)
            actionButtons[index].size = size
        }
        self.actionButtons = actionButtons

        gridSnapDPadOriginals[currentOrientation] = GridSnapOriginal(
            size: dpadSize, relativeCenter: dpadRelativeCenter)
        let snappedDPad = Self.gridSnappedDPadSize(self.dpadSize)
        dpadRelativeCenter = snappedCenter(dpadRelativeCenter, size: snappedDPad)
        self.dpadSize = snappedDPad

        gridSnapActive = true
    }

    /// A legal spawn center for a newly added control, in the
    /// relative space the model stores: the clamped window center,
    /// pushed out of neighbors and chrome walls by the drag solver,
    /// then snapped if grid mode is on. Without a published geometry
    /// it falls back to the plain window center.
    func resolvedSpawnRelativeCenter(size: CGFloat) -> CGPoint {
        guard let geometry = editGeometry else { return CGPoint(x: 0.5, y: 0.5) }
        let geoSize = geometry.geoSize
        let safeArea = geometry.safeArea
        let controlsMinY = geometry.controlsMinY

        var center = ControlsZone.clampToSafeArea(
            CGPoint(x: geoSize.width / 2, y: geoSize.height / 2),
            controlSize: size, geoSize: geoSize, safeArea: safeArea,
            controlsMinY: controlsMinY)
        // The new control is not in the collections yet, so every
        // existing control is a legal obstacle under any dragged ID.
        let placeholderID = UUID()
        for _ in 0..<3 {
            center = collisionResolvedCenter(
                center, previous: nil, draggedID: placeholderID,
                draggedIsDPad: false, controlSize: size,
                geoSize: geoSize, safeArea: safeArea, controlsMinY: controlsMinY)
            center = ControlsZone.clampToSafeArea(
                center, controlSize: size, geoSize: geoSize, safeArea: safeArea,
                controlsMinY: controlsMinY)
        }
        if gridSnapActive {
            center = ControlsZone.snappedToEditGrid(
                center, controlSize: size, geoSize: geoSize,
                safeArea: safeArea, controlsMinY: controlsMinY)
        }
        return CGPoint(
            x: center.x / max(geoSize.width, 1),
            y: center.y / max(geoSize.height, 1))
    }
}
