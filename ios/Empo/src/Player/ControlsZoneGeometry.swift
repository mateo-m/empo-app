import SwiftUI
import UIKit

/// Pure geometry helpers for placing on-screen controls. Lifted out of
/// PlayerView so the layout math is testable / diffable in isolation
/// and PlayerView stays focused on state + view composition.

enum ControlsZone {
    static let padding: CGFloat = 12.0
    static let innerPadding: CGFloat = 6.0
    static let toolbarGap: CGFloat = 8.0
    static let toolbarEdgePad: CGFloat = 4.0
    static let editToolbarHalfHeight: CGFloat = 20.0
    static let minLandscapeInset: CGFloat = 12.0
    static let fallbackDeviceCornerRadius: CGFloat = 55.0
    static let dragScaleFactor: CGFloat = 1.08

    /// Minimum vertical space below the game rect required to place
    /// the toolbar + controls in the dedicated zone below the game.
    /// When the game fills most of the screen (fixedAspectRatio off)
    /// there isn't enough room, so we fall back to overlay mode (same
    /// as landscape: toolbar at top, controls over the game).
    static let minControlsZoneHeight: CGFloat = 120

    static func bounds(controlsMinY: CGFloat, safeArea: EdgeInsets, geoSize: CGSize) -> CGRect {
        let pad = padding
        let top = controlsMinY + pad
        let bottom = geoSize.height - safeArea.bottom - pad
        let leading = safeArea.leading + pad
        let trailing = geoSize.width - safeArea.trailing - pad
        return CGRect(x: leading, y: top, width: trailing - leading, height: bottom - top)
    }

    static func cornerRadii(safeArea: EdgeInsets) -> (top: CGFloat, bottom: CGFloat) {
        let pad = padding
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen
        let deviceCorner = (screen?.value(forKey: "displayCornerRadius") as? CGFloat) ?? fallbackDeviceCornerRadius
        let horizontalGap = safeArea.leading + pad
        let bottomGap = safeArea.bottom + pad
        let minGap = min(horizontalGap, bottomGap)
        let bottom = max(deviceCorner - minGap, Radius.sm)
        let top = Radius.xl
        return (top, bottom)
    }

    static func useOverlayLayout(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, geoHeight: CGFloat) -> Bool {
        guard isPortrait, gameRect.height > 0 else { return false }
        let spaceBelow = geoHeight - (gameRect.origin.y + gameRect.height) - safeArea.bottom
        return spaceBelow < minControlsZoneHeight
    }

    /// Top edge of the controls zone: controls can only live below
    /// this Y. In portrait with space below the game, the zone begins
    /// right at the game's bottom edge (toolbar is now at the top so
    /// it doesn't push controls down). In overlay / landscape, the
    /// zone begins below the toolbar that sits in the top-right.
    static func toolbarBottomY(isPortrait: Bool, gameRect: CGRect, safeArea: EdgeInsets, btnSize: CGFloat, geoHeight: CGFloat) -> CGFloat {
        if isPortrait && gameRect.height > 0 && !useOverlayLayout(isPortrait: isPortrait, gameRect: gameRect, safeArea: safeArea, geoHeight: geoHeight) {
            return gameRect.origin.y + gameRect.height + toolbarGap
        } else {
            let topInset = max(safeArea.top, minLandscapeInset)
            return topInset + toolbarEdgePad + btnSize + toolbarEdgePad
        }
    }

    /// Always anchor the toolbar to the top-right of the device
    /// viewport. In portrait we used to tuck it below the game rect,
    /// which left the keyboard-toggle button covered by the keyboard
    /// whenever it was up. Placing it at the top keeps it reachable
    /// in every orientation + layout mode.
    static func toolbarOrigin(safeArea: EdgeInsets, geoSize: CGSize, btnSize: CGFloat, gap: CGFloat, count: CGFloat) -> CGPoint {
        let totalW = count * btnSize + (count - 1) * gap
        let rightInset = max(safeArea.trailing, minLandscapeInset)
        let topInset = max(safeArea.top, minLandscapeInset)
        let x = geoSize.width - rightInset - toolbarEdgePad - totalW / 2
        let y = topInset + toolbarEdgePad + btnSize / 2
        return CGPoint(x: x, y: y)
    }

    static func absolutePosition(for relativeCenter: CGPoint, in size: CGSize, controlSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat) -> CGPoint {
        let pad = padding + innerPadding
        let hw = controlSize.width * 0.5
        let hh = controlSize.height * 0.5
        let minX = safeArea.leading + pad + hw
        let minY = max(safeArea.top + pad + hh, controlsMinY + pad + hh)
        let maxX = size.width - safeArea.trailing - pad - hw
        let maxY = size.height - safeArea.bottom - pad - hh
        let cx = max(minX, min(relativeCenter.x * size.width, maxX))
        let cy = max(minY, min(relativeCenter.y * size.height, maxY))
        let zone = bounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: size)
        let radii = cornerRadii(safeArea: safeArea)
        return clampToRoundedCorners(CGPoint(x: cx, y: cy), controlHalf: max(hw, hh), zone: zone, radii: radii)
    }

    static func clampToSafeArea(_ point: CGPoint, controlSize: CGFloat, geoSize: CGSize, safeArea: EdgeInsets, controlsMinY: CGFloat) -> CGPoint {
        let pad = padding + innerPadding
        let hw = controlSize * 0.5
        let x = max(safeArea.leading + pad + hw, min(point.x, geoSize.width - safeArea.trailing - pad - hw))
        let minY = max(safeArea.top + pad + hw, controlsMinY + pad + hw)
        let y = max(minY, min(point.y, geoSize.height - safeArea.bottom - pad - hw))
        let zone = bounds(controlsMinY: controlsMinY, safeArea: safeArea, geoSize: geoSize)
        let radii = cornerRadii(safeArea: safeArea)
        return clampToRoundedCorners(CGPoint(x: x, y: y), controlHalf: hw, zone: zone, radii: radii)
    }

    static func clampToRoundedCorners(_ point: CGPoint, controlHalf: CGFloat, zone: CGRect, radii: (top: CGFloat, bottom: CGFloat)) -> CGPoint {
        var p = point
        let corners: [(cx: CGFloat, cy: CGFloat, r: CGFloat)] = [
            (zone.minX + radii.top, zone.minY + radii.top, radii.top),
            (zone.maxX - radii.top, zone.minY + radii.top, radii.top),
            (zone.minX + radii.bottom, zone.maxY - radii.bottom, radii.bottom),
            (zone.maxX - radii.bottom, zone.maxY - radii.bottom, radii.bottom),
        ]
        for corner in corners {
            let inCornerX = (p.x < corner.cx && corner.cx <= zone.minX + max(radii.top, radii.bottom))
                         || (p.x > corner.cx && corner.cx >= zone.maxX - max(radii.top, radii.bottom))
            let inCornerY = (p.y < corner.cy && corner.cy <= zone.minY + max(radii.top, radii.bottom))
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
