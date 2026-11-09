// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

extension ControlsLayout {
    struct EditGeometry: Equatable {
        var geoSize: CGSize
        var safeArea: EdgeInsets
        var controlsMinY: CGFloat
    }

    var newControlSize: CGFloat {
        let size = CGFloat(ControlLimits.defaultButtonSize)
        return gridSnapActive ? Self.gridSnappedSize(size) : size
    }

    private func snappedToGrid(
        _ point: CGPoint, size: CGFloat, in geometry: EditGeometry
    )
        -> CGPoint
    {
        ControlsZone.pushedOutOfKeepout(
            ControlsZone.snappedToEditGrid(
                point, controlSize: size, geoSize: geometry.geoSize,
                safeArea: geometry.safeArea, controlsMinY: geometry.controlsMinY),
            controlHalf: size / 2, keepout: toolbarKeepout,
            geoSize: geometry.geoSize, safeArea: geometry.safeArea,
            controlsMinY: geometry.controlsMinY)
    }

    /// The old values stay in a record, so a toggle off before Done
    /// puts them back.
    func applyGridSnap(geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat) {
        guard !gridSnapActive else { return }
        let geometry = EditGeometry(geoSize: geoSize, safeArea: safeArea, controlsMinY: controlsMinY)
        func snappedCenter(_ relative: CGPoint, size: CGFloat) -> CGPoint {
            let absolute = ControlsZone.absolutePosition(
                for: relative, in: geoSize,
                controlSize: CGSize(width: size, height: size),
                safeArea: safeArea, controlsMinY: controlsMinY, keepout: toolbarKeepout)
            let snapped = snappedToGrid(absolute, size: size, in: geometry)
            return CGPoint(x: snapped.x / geoSize.width, y: snapped.y / geoSize.height)
        }
        func snapped<Control: PlacedControl>(_ controls: [Control]) -> [Control] {
            controls.map { control in
                gridSnapOriginals[control.id] = GridSnapOriginal(
                    size: control.size, relativeCenter: control.relativeCenter)
                var control = control
                control.size = Self.gridSnappedSize(control.size)
                control.relativeCenter = snappedCenter(control.relativeCenter, size: control.size)
                return control
            }
        }

        buttons = snapped(buttons)
        actionButtons = snapped(actionButtons)

        gridSnapDPadOriginals[currentOrientation] = GridSnapOriginal(
            size: dpadSize, relativeCenter: dpadRelativeCenter)
        let snappedDPad = Self.gridSnappedDPadSize(self.dpadSize)
        dpadRelativeCenter = snappedCenter(dpadRelativeCenter, size: snappedDPad)
        self.dpadSize = snappedDPad

        gridSnapActive = true
    }

    func resolvedSpawnRelativeCenter(size: CGFloat) -> CGPoint {
        guard let geometry = editGeometry else { return CGPoint(x: 0.5, y: 0.5) }
        let geoSize = geometry.geoSize
        let safeArea = geometry.safeArea
        let controlsMinY = geometry.controlsMinY

        var center = ControlsZone.clampToSafeArea(
            CGPoint(x: geoSize.width / 2, y: geoSize.height / 2),
            controlSize: size, geoSize: geoSize, safeArea: safeArea,
            controlsMinY: controlsMinY, keepout: toolbarKeepout)
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
                controlsMinY: controlsMinY, keepout: toolbarKeepout)
        }
        if gridSnapActive {
            center = snappedToGrid(center, size: size, in: geometry)
        }
        return CGPoint(
            x: center.x / max(geoSize.width, 1),
            y: center.y / max(geoSize.height, 1))
    }
}
