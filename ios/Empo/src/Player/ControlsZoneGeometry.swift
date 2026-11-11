// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI
import UIKit

enum ControlsZone {
    static let padding: CGFloat = 12.0
    static let innerPadding: CGFloat = 6.0
    static let toolbarGap: CGFloat = 8.0
    static let toolbarEdgePad: CGFloat = 4.0
    static let minLandscapeInset: CGFloat = 12.0
    static let fallbackDeviceCornerRadius: CGFloat = 55.0
    static let dragScaleFactor: CGFloat = 1.08
    static let editGridStep: CGFloat = 10.0

    /// With less space below the game, the controls go over the game.
    static let minControlsZoneHeight: CGFloat = 120

    static func bounds(controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize) -> CGRect {
        let pad = padding
        let top = controlsMinY + pad
        let bottom = geoSize.height - safeArea.bottom - pad
        let leading = safeArea.leading + pad
        let trailing = geoSize.width - safeArea.trailing - pad
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }

    /// `absolutePosition` runs for each control at each frame of a zone
    /// animation, and the KVC read of `displayCornerRadius` costs many
    /// UIKit calls. An access before a scene exists must not keep the
    /// fallback.
    private static var cachedDeviceCornerRadius: CGFloat?

    private static var deviceCornerRadius: CGFloat {
        if let cachedDeviceCornerRadius { return cachedDeviceCornerRadius }
        guard
            let screen = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen })
                .first
        else { return fallbackDeviceCornerRadius }
        let radius =
            (screen.value(forKey: "displayCornerRadius") as? CGFloat)
            ?? fallbackDeviceCornerRadius
        cachedDeviceCornerRadius = radius
        return radius
    }

    static func cornerRadii(safeArea: EdgeInsets) -> (top: CGFloat, bottom: CGFloat) {
        let pad = padding
        let horizontalGap = safeArea.leading + pad
        let bottomGap = safeArea.bottom + pad
        let minGap = min(horizontalGap, bottomGap)
        let bottom = max(deviceCornerRadius - minGap, Radius.sm)
        let top = Radius.xl
        return (top, bottom)
    }

    static func useOverlayLayout(
        isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoHeight: CGFloat,
        forcedOverlay: Bool? = nil
    ) -> Bool {
        if let forcedOverlay { return forcedOverlay }
        guard isPortrait, gameRect.height > 0 else { return false }
        let spaceBelow = geoHeight - (gameRect.origin.y + gameRect.height) - safeArea.bottom
        return spaceBelow < minControlsZoneHeight
    }

    /// The top leading corner of the chrome when the toolbar is a row
    /// at the top of the screen.
    static func topChromeOrigin(safeArea: EdgeInsets) -> CGPoint {
        CGPoint(
            x: max(safeArea.leading, minLandscapeInset) + toolbarEdgePad,
            y: max(safeArea.top, minLandscapeInset) + toolbarEdgePad)
    }

    static func landscapeControlsTopInset(safeArea: EdgeInsets, toolbarButtonSize: CGFloat) -> CGFloat {
        topChromeOrigin(safeArea: safeArea).y + toolbarButtonSize + toolbarEdgePad
    }

    /// The top edge of the controls zone.
    static func toolbarBottomY(
        isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, btnSize: CGFloat,
        geoHeight: CGFloat, forcedOverlay: Bool? = nil
    ) -> CGFloat {
        if isPortrait && gameRect.height > 0
            && !useOverlayLayout(
                isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea,
                geoHeight: geoHeight, forcedOverlay: forcedOverlay)
        {
            return gameRect.origin.y + gameRect.height + toolbarGap
        } else {
            return landscapeControlsTopInset(safeArea: safeArea, toolbarButtonSize: btnSize)
        }
    }

    struct ToolbarPlacement {
        let center: CGPoint
        let isVertical: Bool
        let length: CGFloat
        let thickness: CGFloat

        var frame: CGRect {
            let size =
                isVertical
                ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
            return CGRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
                height: size.height)
        }
    }

    /// A toolbar column in a sensor strip gives the strip to the
    /// controls. Only `toolbarKeepout` stays closed to them.
    static func controlsSafeArea(_ safeArea: EdgeInsets, toolbar: ToolbarPlacement) -> EdgeInsets {
        guard toolbar.isVertical else { return safeArea }
        return EdgeInsets(top: safeArea.top, leading: 0, bottom: safeArea.bottom, trailing: 0)
    }

    /// The toolbar column, from the top of the screen to the column's
    /// bottom and out to the screen edge. `.null` without a column.
    static func toolbarKeepout(_ toolbar: ToolbarPlacement, geoSize: CGSize) -> CGRect {
        guard toolbar.isVertical else { return .null }
        let column = toolbar.frame.insetBy(dx: -toolbarEdgePad, dy: -toolbarEdgePad)
        let minX = column.midX > geoSize.width / 2 ? column.minX : 0
        let maxX = column.midX > geoSize.width / 2 ? geoSize.width : column.maxX
        return CGRect(x: minX, y: 0, width: maxX - minX, height: column.maxY)
    }

    /// The keep-out touches the top and the side edge of the screen,
    /// so a control leaves it either away from that side or down
    /// below the column, whichever legal move is shorter. Without a
    /// legal move, the control stays on the column, not off-screen.
    static func pushedOutOfKeepout(
        _ point: CGPoint, controlHalf: CGFloat, keepout: CGRect,
        geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat
    ) -> CGPoint {
        let blocked = keepout.insetBy(dx: -(controlHalf + innerPadding), dy: -(controlHalf + innerPadding))
        guard !keepout.isNull, blocked.contains(point) else { return point }
        let pad = padding + innerPadding
        let minX = safeArea.leading + pad + controlHalf
        let maxX = geoSize.width - safeArea.trailing - pad - controlHalf
        let minY = max(safeArea.top, controlsMinY) + pad + controlHalf
        let maxY = geoSize.height - safeArea.bottom - pad - controlHalf
        let exits = [
            CGPoint(x: keepout.minX > 0 ? blocked.minX : blocked.maxX, y: point.y),
            CGPoint(x: point.x, y: blocked.maxY),
        ].filter { $0.x >= minX && $0.x <= maxX && $0.y >= minY && $0.y <= maxY }
        return exits.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
            ?? point
    }

    /// A sensor strip takes the toolbar as a column, in the highest gap
    /// of the strip that the system does not draw over.
    static func toolbarPlacement(
        safeArea: EdgeInsets, geoSize: CGSize, occluded: [CGRect], btnSize: CGFloat, gap: CGFloat,
        count: CGFloat
    ) -> ToolbarPlacement {
        let length = count * btnSize + (count - 1) * gap
        if let edge = safeArea.sensorStripEdge(minWidth: btnSize + 2 * toolbarEdgePad) {
            let strip =
                edge == .trailing
                ? CGRect(
                    x: geoSize.width - safeArea.trailing, y: 0, width: safeArea.trailing,
                    height: geoSize.height)
                : CGRect(x: 0, y: 0, width: safeArea.leading, height: geoSize.height)
            let y = stripColumnCenterY(
                strip: strip, occluded: occluded, top: safeArea.top,
                bottom: geoSize.height - safeArea.bottom, length: length)
            let x = sensorStripColumnX(strip: strip, occluded: occluded)
            return ToolbarPlacement(
                center: CGPoint(x: x, y: y), isVertical: true, length: length, thickness: btnSize)
        }
        let rightInset = max(safeArea.trailing, minLandscapeInset)
        let x = geoSize.width - rightInset - toolbarEdgePad - length / 2
        let y = topChromeOrigin(safeArea: safeArea).y + btnSize / 2
        return ToolbarPlacement(
            center: CGPoint(x: x, y: y), isVertical: false, length: length, thickness: btnSize)
    }

    /// Without a gap that fits, the column centers in the strip.
    private static func stripColumnCenterY(
        strip: CGRect, occluded: [CGRect], top: CGFloat, bottom: CGFloat, length: CGFloat
    ) -> CGFloat {
        var gapTop = top
        let blocks = occluded.filter { $0.intersects(strip) }.sorted { $0.minY < $1.minY }
        for block in blocks + [CGRect(x: strip.minX, y: bottom, width: strip.width, height: 0)] {
            if block.minY - gapTop >= length + 2 * toolbarEdgePad {
                return gapTop + toolbarEdgePad + length / 2
            }
            gapTop = max(gapTop, block.maxY)
        }
        return (top + bottom) / 2
    }

    /// Snaps the top leading edge of the control, not its center, so the
    /// borders sit on the grid at all sizes. The grid starts at the top
    /// leading corner of the zone.
    static func snappedToEditGrid(
        _ point: CGPoint, controlSize: CGFloat, geoSize: CGSize,
        safeArea: EdgeInsets, controlsMinY: CGFloat
    ) -> CGPoint {
        let zone = bounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let half = controlSize / 2
        return CGPoint(
            x: zone.minX + ((point.x - half - zone.minX) / editGridStep).rounded()
                * editGridStep + half,
            y: zone.minY + ((point.y - half - zone.minY) / editGridStep).rounded()
                * editGridStep + half)
    }

    static func absolutePosition(
        for relativeCenter: CGPoint, in size: CGSize, controlSize: CGFloat, safeArea: EdgeInsets,
        controlsMinY: CGFloat, keepout: CGRect
    ) -> CGPoint {
        clampToSafeArea(
            CGPoint(x: relativeCenter.x * size.width, y: relativeCenter.y * size.height),
            controlSize: controlSize, geoSize: size, safeArea: safeArea, controlsMinY: controlsMinY,
            keepout: keepout)
    }

    static func clampToSafeArea(
        _ point: CGPoint, controlSize: CGFloat, geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat,
        keepout: CGRect
    ) -> CGPoint {
        let pad = padding + innerPadding
        let hw = controlSize * 0.5
        let x = max(safeArea.leading + pad + hw, min(point.x, geoSize.width - safeArea.trailing - pad - hw))
        let minY = max(safeArea.top + pad + hw, controlsMinY + pad + hw)
        let y = max(minY, min(point.y, geoSize.height - safeArea.bottom - pad - hw))
        let zone = bounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let radii = cornerRadii(safeArea: safeArea)
        let pushed = pushedOutOfKeepout(
            CGPoint(x: x, y: y), controlHalf: hw, keepout: keepout,
            geoSize: geoSize, safeArea: safeArea, controlsMinY: controlsMinY)
        return clampToRoundedCorners(pushed, controlHalf: hw, zone: zone, radii: radii)
    }

    static func clampToRoundedCorners(
        _ point: CGPoint, controlHalf: CGFloat, zone: CGRect, radii: (top: CGFloat, bottom: CGFloat)
    ) -> CGPoint {
        var p = point
        let corners: [(cx: CGFloat, cy: CGFloat, r: CGFloat)] = [
            (zone.minX + radii.top, zone.minY + radii.top, radii.top),
            (zone.maxX - radii.top, zone.minY + radii.top, radii.top),
            (zone.minX + radii.bottom, zone.maxY - radii.bottom, radii.bottom),
            (zone.maxX - radii.bottom, zone.maxY - radii.bottom, radii.bottom),
        ]
        for corner in corners {
            let inCornerX =
                (p.x < corner.cx && corner.cx <= zone.minX + max(radii.top, radii.bottom))
                || (p.x > corner.cx && corner.cx >= zone.maxX - max(radii.top, radii.bottom))
            let inCornerY =
                (p.y < corner.cy && corner.cy <= zone.minY + max(radii.top, radii.bottom))
                || (p.y > corner.cy && corner.cy >= zone.maxY - max(radii.top, radii.bottom))
            guard inCornerX && inCornerY else { continue }
            let dx = p.x - corner.cx
            let dy = p.y - corner.cy
            let dist = sqrt(dx * dx + dy * dy)
            let maxDist = corner.r - controlHalf - innerPadding
            if maxDist > 0 && dist > maxDist {
                let scale = maxDist / dist
                p.x = corner.cx + dx * scale
                p.y = corner.cy + dy * scale
            }
        }
        return p
    }
}
