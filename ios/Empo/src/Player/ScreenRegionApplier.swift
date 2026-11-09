// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// Sends the screen region of the active game to the engine. The
/// engine ignores a region whose orientation tag does not match the
/// window. The stored fractions never change, but the sent region is
/// clamped to the safe area of this device.
@MainActor
final class ScreenRegionApplier {
    private var activeContainer: GameContainer?
    private var tokens: [NSObjectProtocol] = []
    /// A gizmo drag overrides the resolved region until it ends.
    private var previewActive = false
    /// The player body reads the region on each render, and a drag
    /// renders at up to 120 Hz. Without the cache, each render reads
    /// files on the main thread.
    private var resolutionCache: ScreenResolution.Result?
    /// An invalid file in the chain logs its findings once for each
    /// session, not on each rotation and pin change.
    private var loggedFindingSignatures: Set<String> = []
    private var animationTask: Task<Void, Never>?

    /// The aspect of the game picture, from the gameRect that the
    /// engine publishes. A preset has no rect until the first publish.
    private var gameAspect: CGFloat?

    // MARK: - Session

    /// Call this after `gamecore_resetSessionState()` clears the region
    /// of the previous session, and before the engine boots. The first
    /// layout pass of the engine reads the region.
    func beginSession(container: GameContainer) {
        animationTask?.cancel()
        activeContainer = container
        previewActive = false
        resolutionCache = nil
        gameAspect = nil
        loggedFindingSignatures.removeAll()
        observeIfNeeded()
        apply()
    }

    func endSession() {
        // A reset glide that continues after the clear below writes
        // the regions of the old game into the engine.
        animationTask?.cancel()
        activeContainer = nil
        previewActive = false
        resolutionCache = nil
        gamecore_clearHostViewportRegion()
    }

    // MARK: - Apply

    /// The engine holds one region. Rotation applies again through the
    /// geometry change of the player.
    func apply() {
        guard activeContainer != nil, !previewActive, let resolved = resolve() else { return }
        let portrait = windowIsPortrait
        let placement = (portrait ? resolved.portrait : resolved.landscape).placement
        // Without a game aspect, a preset gives no region, and the
        // engine stays on automatic placement.
        send(placement.flatMap { region(for: $0) }, isPortrait: portrait)
    }

    func resolvedPlacement(isPortrait: Bool) -> ScreenPlacement? {
        guard let resolved = resolve() else { return nil }
        return (isPortrait ? resolved.portrait : resolved.landscape).placement
    }

    /// A preset gets its rect from the current window, so one profile
    /// places the game correctly on each device.
    func region(for placement: ScreenPlacement) -> ScreenRegion? {
        if case .region(let region) = placement { return region }
        return AppWindow.canvas?.region(for: placement, aspect: gameAspect)
    }

    func gameRectChanged(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let aspect = rect.width / rect.height
        guard gameAspect != aspect else { return }
        let hadAspect = gameAspect != nil
        gameAspect = aspect
        if !hadAspect || currentPlacementIsPreset {
            apply()
        }
    }

    private var currentPlacementIsPreset: Bool {
        if case .preset = resolvedPlacement(isPortrait: windowIsPortrait) {
            return true
        }
        return false
    }

    private func resolve() -> ScreenResolution.Result? {
        guard let container = activeContainer else { return nil }
        if let cached = resolutionCache { return cached }
        let store = LayoutProfilesManager.store
        let result = ScreenResolution.resolve(
            pin: store.loadPin(forGameFolder: container.url).pin,
            defaultProfileName: LayoutProfilesManager.defaultProfileName,
            readScreen: { [self] name in
                let read = store.readScreen(name)
                if let findings = read?.findings, !findings.isEmpty {
                    let signature = name + "|" + findings.joined(separator: ";")
                    if loggedFindingSignatures.insert(signature).inserted {
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

    /// nil previews automatic placement.
    func preview(_ region: ScreenRegion?, isPortrait: Bool) {
        animationTask?.cancel()
        previewActive = true
        send(region, isPortrait: isPortrait)
    }

    /// The engine cannot animate its own layout change. This glides
    /// from `start` to an estimate of automatic placement, then gives
    /// the engine its real automatic placement.
    func resetToAuto(from start: ScreenRegion?, in canvas: ScreenCanvas, isPortrait: Bool) {
        guard let start,
            let end = canvas.region(
                for: .preset(Self.automaticPreset), aspect: gameAspect ?? GameAspect.typical)
        else {
            preview(nil, isPortrait: isPortrait)
            return
        }
        animationTask?.cancel()
        previewActive = true
        animationTask = Task { @MainActor [weak self] in
            let steps = 15
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                self?.send(
                    ScreenRegion(
                        x: start.x + (end.x - start.x) * eased,
                        y: start.y + (end.y - start.y) * eased,
                        w: start.w + (end.w - start.w) * eased,
                        h: start.h + (end.h - start.h) * eased),
                    isPortrait: isPortrait)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.send(nil, isPortrait: isPortrait)
        }
    }

    /// The preset that matches the automatic placement of the engine.
    private static var automaticPreset: ScreenPreset {
        switch gamecore_getVerticalAlignment() {
        case GAMECORE_VALIGN_TOP: .top
        case GAMECORE_VALIGN_CENTER: .center
        default: .topCenter
        }
    }

    /// A save can write files just before this, so the cache goes
    /// first.
    func endPreview() {
        animationTask?.cancel()
        previewActive = false
        resolutionCache = nil
        apply()
    }

    /// Shows the pending edit of this orientation, or the region on
    /// disk when no edit is pending.
    func show(pending edit: ControlsLayout.ScreenEdit?, isPortrait: Bool) {
        guard let edit else {
            endPreview()
            return
        }
        preview(edit.placement.flatMap { region(for: $0) }, isPortrait: isPortrait)
    }

    // MARK: - Internals

    private var windowIsPortrait: Bool { AppWindow.canvas?.isPortrait ?? true }

    private func send(_ region: ScreenRegion?, isPortrait: Bool) {
        guard let region else {
            gamecore_clearHostViewportRegion()
            return
        }
        let clamped = AppWindow.canvas?.clampedToSafeArea(region) ?? region
        gamecore_setHostViewportRegion(
            Float(clamped.x), Float(clamped.y), Float(clamped.w), Float(clamped.h),
            isPortrait)
    }

    private func observeIfNeeded() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .layoutPinDidChange, .layoutProfileDidChange, .layoutDefaultProfileDidChange,
        ]
        for name in names {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.resolutionCache = nil
                        self?.apply()
                    }
                })
        }
    }
}
