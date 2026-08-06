import GameProbe
import SwiftUI
import UIKit

/// Sends the resolved screen region for the active game to the
/// engine bridge. Fractions are dimensionless window fractions; the
/// engine ignores a region whose orientation tag does not match the
/// window, so rotation can never paint the wrong orientation's
/// region.
///
/// Apply-time clamp: the stored fractions never change, but the SENT
/// region is intersected with the current safe area, so a profile
/// authored on a notchless device cannot put game content under
/// another device's Dynamic Island. The minimum size survives the
/// clamp by shifting before shrinking.
@MainActor
enum ScreenRegionApplier {
    private(set) static var activeContainer: GameContainer?
    private static var tokens: [NSObjectProtocol] = []
    /// A gizmo drag overrides the resolved region until it ends.
    private static var previewActive = false

    // MARK: - Session lifecycle

    /// Called from the engine configure path, after
    /// `mkxp_resetSessionState()` cleared the previous session's
    /// region and before the engine boots (the boot-time recalc
    /// already consumes the bridge statics).
    static func beginSession(container: GameContainer) {
        activeContainer = container
        previewActive = false
        observeIfNeeded()
        apply()
    }

    static func endSession() {
        activeContainer = nil
        previewActive = false
        mkxp_clearHostViewportRegion()
    }

    // MARK: - Apply

    /// Resolves and sends the region for the CURRENT orientation.
    /// The bridge holds one region; rotation re-applies through the
    /// player's geometry change hook.
    static func apply() {
        guard let container = activeContainer, !previewActive else { return }
        let store = LayoutProfilesManager.store
        let pin = store.loadPin(forGameFolder: container.url).pin
        let resolved = ScreenResolution.resolve(
            pin: pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { name in
                let read = store.readScreen(name)
                if let findings = read?.findings, !findings.isEmpty {
                    for line in findings {
                        store.appendLog(name, file: ScreenRegionFile.fileName, line: line)
                    }
                }
                return read
            }
        )
        let portrait = currentWindowIsPortrait
        let outcome = portrait ? resolved.portrait : resolved.landscape
        send(outcome.region, isPortrait: portrait)
    }

    /// The region the chain resolves to right now, for the gizmo's
    /// base rect. No logging: apply() owns the findings path.
    static func resolvedRegion(isPortrait: Bool) -> ScreenRegion? {
        guard let container = activeContainer else { return nil }
        let store = LayoutProfilesManager.store
        let resolved = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { store.readScreen($0) }
        )
        return (isPortrait ? resolved.portrait : resolved.landscape).region
    }

    /// Live gizmo feed: overrides the resolved region during a drag.
    /// nil previews automatic placement.
    static func preview(_ region: ScreenRegion?, isPortrait: Bool) {
        previewActive = true
        send(region, isPortrait: isPortrait)
    }

    /// Drag ended (committed or cancelled): back to the resolved
    /// state.
    static func endPreview() {
        previewActive = false
        apply()
    }

    /// The player's geometry changed (rotation, window resize).
    static func geometryChanged() {
        guard activeContainer != nil, !previewActive else { return }
        apply()
    }

    // MARK: - Internals

    private static func send(_ region: ScreenRegion?, isPortrait: Bool) {
        guard let region else {
            mkxp_clearHostViewportRegion()
            return
        }
        let clamped = clampToSafeArea(region)
        mkxp_setHostViewportRegion(
            Float(clamped.x), Float(clamped.y), Float(clamped.w), Float(clamped.h),
            isPortrait)
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    private static var currentWindowIsPortrait: Bool {
        guard let bounds = window?.bounds else { return true }
        return bounds.width < bounds.height
    }

    /// Shift-then-shrink into the safe area, in fraction space.
    static func clampToSafeArea(_ region: ScreenRegion) -> ScreenRegion {
        guard let window else { return region }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return region }
        let insets = window.safeAreaInsets

        let safeX = Double(insets.left / bounds.width)
        let safeY = Double(insets.top / bounds.height)
        let safeMaxX = Double((bounds.width - insets.right) / bounds.width)
        let safeMaxY = Double((bounds.height - insets.bottom) / bounds.height)

        var w = min(region.w, safeMaxX - safeX)
        var h = min(region.h, safeMaxY - safeY)
        w = max(w, min(ScreenRegionFile.minFraction, safeMaxX - safeX))
        h = max(h, min(ScreenRegionFile.minFraction, safeMaxY - safeY))
        let x = min(max(region.x, safeX), safeMaxX - w)
        let y = min(max(region.y, safeY), safeMaxY - h)
        return ScreenRegion(x: x, y: y, w: w, h: h)
    }

    // MARK: - Notifications

    private static func observeIfNeeded() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .layoutPinDidChange, .layoutProfileDidChange, .layoutDefaultProfileDidChange,
        ]
        for name in names {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        // Cheap full re-resolve; origin filtering is
                        // unnecessary because apply() is idempotent
                        // and never writes files or posts back.
                        apply()
                    }
                })
        }
    }
}
