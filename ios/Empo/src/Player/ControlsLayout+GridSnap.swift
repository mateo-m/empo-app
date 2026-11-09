// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// The control that a drag in edit mode moves.
enum EditDragSubject: Hashable {
    case dpad
    case control(UUID)
    /// A control that the add flow places. It is not in the layout yet.
    case newControl
}

extension ControlsLayout {
    struct EditGeometry: Equatable {
        var geoSize: CGSize
        var safeArea: EdgeInsets
        var controlsMinY: CGFloat
    }

    struct GridSnapOriginal {
        var size: CGFloat
        var relativeCenter: CGPoint
    }

    static var snapToGrid: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.controlsEditSnapToGrid) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.controlsEditSnapToGrid) }
    }

    static func gridSnappedSize(_ value: CGFloat) -> CGFloat {
        (value / ControlsZone.editGridStep).rounded() * ControlsZone.editGridStep
    }

    /// The arms of the D-pad are thirds of its size, so only a size
    /// in steps of 3 grid steps puts the inner arm borders on the grid.
    static func gridSnappedDPadSize(_ value: CGFloat) -> CGFloat {
        let step = ControlsZone.editGridStep * 3
        return (value / step).rounded() * step
    }

    var newControlSize: CGFloat {
        let size = CGFloat(ControlLimits.defaultButtonSize)
        return gridSnapActive ? Self.gridSnappedSize(size) : size
    }

    // MARK: - Toggle

    /// No undo on exit: `endEditSession()` drops the restore record, so
    /// Done keeps the snap.
    func editModeChanged(_ editing: Bool, in geometry: EditGeometry) {
        guard editing, Self.snapToGrid else { return }
        applyGridSnap(in: geometry)
    }

    /// Off puts back the values from before the snap, because Done did
    /// not run.
    func toggleSnapToGrid(in geometry: EditGeometry) {
        Self.snapToGrid.toggle()
        if Self.snapToGrid {
            applyGridSnap(in: geometry)
        } else {
            revertGridSnap()
        }
    }

    /// The old values stay in a record, so a toggle off before Done
    /// puts them back.
    private func applyGridSnap(in geometry: EditGeometry) {
        guard !gridSnapActive else { return }
        func snappedCenter(_ relative: CGPoint, size: CGFloat) -> CGPoint {
            let snapped = snappedToGrid(
                absoluteCenter(relative, size: size, in: geometry), size: size, in: geometry)
            return CGPoint(x: snapped.x / geometry.geoSize.width, y: snapped.y / geometry.geoSize.height)
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
        let snappedDPad = Self.gridSnappedDPadSize(dpadSize)
        dpadRelativeCenter = snappedCenter(dpadRelativeCenter, size: snappedDPad)
        dpadSize = snappedDPad

        gridSnapActive = true
    }

    private func revertGridSnap() {
        let buttonOriginals = gridSnapOriginals
        let dpadOriginals = gridSnapDPadOriginals
        dropGridSnapRecord()
        for (id, original) in buttonOriginals {
            setPlacement(of: id, size: original.size, relativeCenter: original.relativeCenter)
        }
        for (orientation, original) in dpadOriginals {
            setDPadPlacement(in: orientation, size: original.size, relativeCenter: original.relativeCenter)
        }
    }

    /// A wholesale replacement must call this. If not, a revert puts
    /// the values from before the snap back over the new layout.
    func dropGridSnapRecord() {
        gridSnapOriginals = [:]
        gridSnapDPadOriginals = [:]
        gridSnapActive = false
    }

    // MARK: - Placement

    func resolvedSpawnRelativeCenter(size: CGFloat) -> CGPoint {
        guard let geometry = editGeometry else { return CGPoint(x: 0.5, y: 0.5) }
        let geoSize = geometry.geoSize
        var center = settledCenter(
            CGPoint(x: geoSize.width / 2, y: geoSize.height / 2),
            previous: nil, subject: .newControl, size: size, in: geometry)
        if gridSnapActive {
            center = snappedToGrid(center, size: size, in: geometry)
        }
        return CGPoint(
            x: center.x / max(geoSize.width, 1),
            y: center.y / max(geoSize.height, 1))
    }

    /// The center of the dragged control before the drag, so that the
    /// first event of the drag knows its approach side.
    func absoluteCenter(of subject: EditDragSubject, in geometry: EditGeometry) -> CGPoint? {
        switch subject {
        case .dpad:
            return absoluteCenter(dpadRelativeCenter, size: dpadSize, in: geometry)
        case .control(let id):
            if let button = buttons.first(where: { $0.id == id }) {
                return absoluteCenter(button.relativeCenter, size: button.size, in: geometry)
            }
            if let button = actionButtons.first(where: { $0.id == id }) {
                return absoluteCenter(button.relativeCenter, size: button.size, in: geometry)
            }
            return nil
        case .newControl:
            return nil
        }
    }

    /// The snap comes before the solve, so the clamp and the collision
    /// work on targets on the grid. At a wall or next to a neighbor the
    /// result can be off the grid. When the result still collides, the
    /// control stays at `previous`.
    func resolvedDragCenter(
        _ location: CGPoint, previous: CGPoint?, subject: EditDragSubject, size: CGFloat,
        in geometry: EditGeometry
    ) -> CGPoint {
        let target =
            Self.snapToGrid
            ? ControlsZone.snappedToEditGrid(
                location, controlSize: size, geoSize: geometry.geoSize,
                safeArea: geometry.safeArea, controlsMinY: geometry.controlsMinY)
            : location
        let center = settledCenter(target, previous: previous, subject: subject, size: size, in: geometry)
        if let previous,
            EditDragSolver.collides(
                x: Double(center.x), y: Double(center.y), radius: Double(size) / 2,
                obstacles: obstacles(excluding: subject, in: geometry), walls: chromeWalls)
        {
            return previous
        }
        return center
    }

    // MARK: - Internals

    private func absoluteCenter(_ relative: CGPoint, size: CGFloat, in geometry: EditGeometry) -> CGPoint {
        ControlsZone.absolutePosition(
            for: relative, in: geometry.geoSize,
            controlSize: CGSize(width: size, height: size),
            safeArea: geometry.safeArea, controlsMinY: geometry.controlsMinY, keepout: toolbarKeepout)
    }

    private func clamped(_ point: CGPoint, size: CGFloat, in geometry: EditGeometry) -> CGPoint {
        ControlsZone.clampToSafeArea(
            point, controlSize: size, geoSize: geometry.geoSize, safeArea: geometry.safeArea,
            controlsMinY: geometry.controlsMinY, keepout: toolbarKeepout)
    }

    private func snappedToGrid(_ point: CGPoint, size: CGFloat, in geometry: EditGeometry) -> CGPoint {
        ControlsZone.pushedOutOfKeepout(
            ControlsZone.snappedToEditGrid(
                point, controlSize: size, geoSize: geometry.geoSize,
                safeArea: geometry.safeArea, controlsMinY: geometry.controlsMinY),
            controlHalf: size / 2, keepout: toolbarKeepout,
            geoSize: geometry.geoSize, safeArea: geometry.safeArea,
            controlsMinY: geometry.controlsMinY)
    }

    /// The zone clamp and the collision push can each undo the other at
    /// the zone edges, so the two steps alternate.
    private func settledCenter(
        _ point: CGPoint, previous: CGPoint?, subject: EditDragSubject, size: CGFloat,
        in geometry: EditGeometry
    ) -> CGPoint {
        let obstacles = obstacles(excluding: subject, in: geometry)
        var center = clamped(point, size: size, in: geometry)
        for _ in 0..<3 {
            let resolved = EditDragSolver.resolvedCenter(
                desiredX: Double(center.x), desiredY: Double(center.y),
                previousX: previous.map { Double($0.x) },
                previousY: previous.map { Double($0.y) },
                radius: Double(size) / 2,
                obstacles: obstacles, walls: chromeWalls)
            center = clamped(CGPoint(x: resolved.x, y: resolved.y), size: size, in: geometry)
        }
        return center
    }

    private func obstacles(
        excluding subject: EditDragSubject, in geometry: EditGeometry
    ) -> [EditDragSolver.Circle] {
        func circle(_ relative: CGPoint, _ size: CGFloat) -> EditDragSolver.Circle {
            let absolute = absoluteCenter(relative, size: size, in: geometry)
            return EditDragSolver.Circle(
                x: Double(absolute.x), y: Double(absolute.y), radius: Double(size) / 2)
        }
        var obstacles: [EditDragSolver.Circle] = []
        for button in buttons where subject != .control(button.id) {
            obstacles.append(circle(button.relativeCenter, button.size))
        }
        for button in actionButtons where subject != .control(button.id) {
            obstacles.append(circle(button.relativeCenter, button.size))
        }
        if subject != .dpad {
            obstacles.append(circle(dpadRelativeCenter, dpadSize))
        }
        return obstacles
    }

    private var chromeWalls: [EditDragSolver.Rect] {
        (editChromeFrames + [toolbarKeepout].filter { !$0.isNull }).map {
            EditDragSolver.Rect(
                x: Double($0.minX), y: Double($0.minY),
                width: Double($0.width), height: Double($0.height))
        }
    }
}
