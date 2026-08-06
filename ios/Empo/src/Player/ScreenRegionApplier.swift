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
    /// Resolution cache: the player's body reads `resolvedRegion`
    /// per render, and a drag re-renders at frame rate — without
    /// the cache that is main-thread file IO at up to 120 Hz.
    /// Invalidated on the notifications, session boundaries, and
    /// `endPreview` (a save may have just written files).
    private static var resolutionCache: ScreenResolution.Result?
    /// Log-once guard: an invalid file in the chain would otherwise
    /// re-append identical findings on every rotation and pin
    /// change, unbounded. Cleared per session.
    private static var loggedFindingSignatures: Set<String> = []

    // MARK: - Session lifecycle

    /// Called from the engine configure path, after
    /// `mkxp_resetSessionState()` cleared the previous session's
    /// region and before the engine boots (the boot-time recalc
    /// already consumes the bridge statics).
    static func beginSession(container: GameContainer) {
        animationTask?.cancel()
        activeContainer = container
        previewActive = false
        resolutionCache = nil
        loggedFindingSignatures.removeAll()
        observeIfNeeded()
        apply()
    }

    static func endSession() {
        // A reset glide in flight must die with the session, or it
        // keeps writing the old game's regions into the bridge
        // after the clear below.
        animationTask?.cancel()
        activeContainer = nil
        previewActive = false
        resolutionCache = nil
        mkxp_clearHostViewportRegion()
    }

    // MARK: - Apply

    /// Resolves and sends the region for the CURRENT orientation.
    /// The bridge holds one region; rotation re-applies through the
    /// player's geometry change hook.
    static func apply() {
        guard activeContainer != nil, !previewActive else { return }
        guard let resolved = resolve() else { return }
        let portrait = currentWindowIsPortrait
        let outcome = portrait ? resolved.portrait : resolved.landscape
        send(outcome.region, isPortrait: portrait)
    }

    /// The region the chain resolves to right now, for the gizmo's
    /// base rect. Served from the cache.
    static func resolvedRegion(isPortrait: Bool) -> ScreenRegion? {
        guard let resolved = resolve() else { return nil }
        return (isPortrait ? resolved.portrait : resolved.landscape).region
    }

    private static func resolve() -> ScreenResolution.Result? {
        guard let container = activeContainer else { return nil }
        if let cached = resolutionCache { return cached }
        let store = LayoutProfilesManager.store
        let result = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { name in
                let read = store.readScreen(name)
                if let findings = read?.findings, !findings.isEmpty {
                    let signature = name + "|" + findings.joined(separator: ";")
                    if !loggedFindingSignatures.contains(signature) {
                        loggedFindingSignatures.insert(signature)
                        for line in findings {
                            store.appendLog(
                                name, file: ScreenRegionFile.fileName, line: line)
                        }
                    }
                }
                return read
            }
        )
        resolutionCache = result
        return result
    }

    /// Live gizmo feed: overrides the resolved region during a drag.
    /// nil previews automatic placement.
    static func preview(_ region: ScreenRegion?, isPortrait: Bool) {
        animationTask?.cancel()
        previewActive = true
        send(region, isPortrait: isPortrait)
    }

    private static var animationTask: Task<Void, Never>?

    /// "Reset screen" glide: tween from the active region to the
    /// app-side ESTIMATE of automatic placement, then hand off to
    /// the engine's real auto (a sub-pixel correction at most). The
    /// engine cannot animate its own relayout; interpolated preview
    /// regions at ~60 Hz do it from here.
    static func animateResetToAuto(
        from start: ScreenRegion, toEstimate end: ScreenRegion, isPortrait: Bool
    ) {
        animationTask?.cancel()
        previewActive = true
        animationTask = Task { @MainActor in
            let steps = 15
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                send(
                    ScreenRegion(
                        x: start.x + (end.x - start.x) * eased,
                        y: start.y + (end.y - start.y) * eased,
                        w: start.w + (end.w - start.w) * eased,
                        h: start.h + (end.h - start.h) * eased),
                    isPortrait: isPortrait)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard !Task.isCancelled else { return }
            send(nil, isPortrait: isPortrait)
        }
    }

    /// Drag ended (committed or cancelled): back to the resolved
    /// state. A save may have just written files, so the cache
    /// drops first.
    static func endPreview() {
        animationTask?.cancel()
        previewActive = false
        resolutionCache = nil
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

    /// Shift-then-shrink into the safe area, in fraction space. In
    /// landscape only the left/right insets apply — the engine's
    /// auto path ignores top/bottom there (the home indicator
    /// auto-hides), and clamping harder than auto would make a
    /// full-height region impossible to author.
    static func clampToSafeArea(_ region: ScreenRegion) -> ScreenRegion {
        guard let window else { return region }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return region }
        let insets = window.safeAreaInsets
        let isPortrait = bounds.width < bounds.height

        let safeX = Double(insets.left / bounds.width)
        let safeY = isPortrait ? Double(insets.top / bounds.height) : 0
        let safeMaxX = Double((bounds.width - insets.right) / bounds.width)
        let safeMaxY =
            isPortrait ? Double((bounds.height - insets.bottom) / bounds.height) : 1

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
                        resolutionCache = nil
                        apply()
                    }
                })
        }
    }
}
