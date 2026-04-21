import SwiftUI

private enum SplashTiming {
    static let holdDuration: TimeInterval = 1.2
    static let cycleDuration: TimeInterval = 3
    static let frameInterval: TimeInterval = 1.0 / 60.0
}

struct RootView: View {
    @Environment(\.appState) private var appState
    @Environment(\.engineState) private var engineState
    @Environment(\.controlsLayout) private var layout
    @Environment(\.appSettings) private var settings
    @Namespace private var hero
    @State private var showSplash: Bool
    @State private var splashExiting = false
    @State private var splashDismissed: Bool

    init() {
        let recovering = AppState.shared.pendingCrashRecovery
        _showSplash = State(initialValue: !recovering)
        _splashDismissed = State(initialValue: recovering)
    }
    /// When true, the splash logo cross-fades out and the disclaimer
    /// cross-fades in on top of the same orange background. Flipped at
    /// the 1.2s mark only if the user hasn't acknowledged yet.
    @State private var showDisclaimer = false

    var body: some View {
        ZStack {
            // Always mounted so NavigationStack persists across phases
            GameLibraryView(appState: appState, heroNamespace: hero, splashDismissed: splashDismissed)
                .opacity(appState.phase == .playing ? 0 : 1)
                .allowsHitTesting(appState.phase != .playing)

            // Playing — transparent controls overlay.
            // .transition(.identity) prevents the default fade-in so
            // PlayerView appears at full opacity instantly, even when
            // the phase change is wrapped in withAnimation.  This lets
            // the library fade out smoothly without a cross-fade dim.
            if appState.phase == .playing {
                PlayerView(appState: appState, engineState: engineState, layout: layout)
                    .transition(.identity)
                    .zIndex(1)
            }
        }
        .fontDesign(.rounded)
        .tint(.brand)
        .overlay {
            if showSplash {
                SplashView(
                    exiting: splashExiting,
                    showDisclaimer: showDisclaimer,
                    onAcknowledgeDisclaimer: acknowledgeAndDismissSplash
                )
                .zIndex(10)
            }
        }
        .task {
            if appState.pendingCrashRecovery {
                appState.consumeCrashRecovery()
                return
            }
            // Hold the splash visible for ~1.2s before transitioning
            // to either the disclaimer (first launch) or the library.
            // .task cancels on disappear so if the view is ever torn
            // down early, the sleep unwinds cleanly.
            try? await Task.sleep(for: .milliseconds(Int(SplashTiming.holdDuration * 1000)))
            if settings.needsDisclaimer {
                // Hold the splash open: fade the logo out (by entering
                // the "exiting" visual but without dismissing the
                // container) and reveal the disclaimer. The normal
                // dismissal runs once the user acknowledges.
                withAnimation(Motion.gentle) {
                    showDisclaimer = true
                }
            } else {
                dismissSplash()
            }
        }
        .alert("Something went wrong", isPresented: showErrorAlert) {
            Button("OK") {
                if mkxp_isEngineHung() != 0 {
                    // RGSS thread is still running inside a script that
                    // never yielded to checkShutdown(). The process must
                    // be killed because we cannot respawn Ruby in-place.
                    exit(0)
                }
                if appState.phase != nil {
                    appState.returnToLibrary()
                } else {
                    appState.dismissCrashRecovery()
                }
            }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            if appState.phase == .playing {
                engineState.requestBackgroundPause()
                // If the engine rendered at least one frame, this was a
                // healthy session. Remove the crash marker so a force-kill
                // from the app switcher won't trigger a false crash alert.
                // Black-screen crashes leave engineReady false, so the
                // marker persists and the alert still fires.
                if appState.engineReady {
                    appState.clearCrashMarkerForBackground()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if appState.phase == .playing {
                engineState.resumeFromBackground()
                // Re-create the crash marker so a crash after resume is
                // still detected on the next launch.
                appState.restoreCrashMarkerForForeground()
            }
        }
    }

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )
    }

    /// Normal splash exit: fade background + logo + any disclaimer that
    /// might still be on screen, then unmount the splash overlay.
    private func dismissSplash() {
        splashDismissed = true
        withAnimation(Motion.slow) {
            splashExiting = true
        } completion: {
            showSplash = false
            appState.consumeCrashRecovery()
        }
    }

    /// Called from the disclaimer's "I understand" button. Persists
    /// the acknowledgment and runs the usual splash exit animation.
    private func acknowledgeAndDismissSplash() {
        settings.acknowledgeDisclaimer()
        dismissSplash()
    }
}


private struct SplashView: View {
    /// True when the whole splash is animating out (fades background +
    /// everything on top of it). This is the final exit phase.
    let exiting: Bool
    /// True when the disclaimer has taken over - logo should fade out
    /// and the disclaimer should fade in. Splash stays mounted.
    let showDisclaimer: Bool
    let onAcknowledgeDisclaimer: () -> Void

    @State private var entered = false

    /// Combined "logo should be visually absent" flag. True during the
    /// disclaimer phase OR during the full exit. Kept as a single
    /// variable so the same fade/scale/blur treatment drives both.
    private var logoHidden: Bool { exiting || showDisclaimer }

    var body: some View {
        ZStack {
            Color.brand
                .ignoresSafeArea()
                .opacity(exiting ? 0 : 1)

            PixelDitherPattern(color: .white)
                .ignoresSafeArea()
                .opacity(exiting ? 0 : 1)

            // Logo + wordmark. During the disclaimer phase these fade/
            // blur/scale out but the splash background stays. Same
            // treatment on the full exit.
            VStack(spacing: Spacing.lg) {
                Text(AppInfo.name)
                    .font(AppFont.wordmark)
                    .foregroundStyle(.white)
                    .heroTitleShadow()
            }
            .blur(radius: logoHidden ? 10 : 0)
            .scaleEffect(logoHidden ? 0.8 : (entered ? 1 : 0.8))
            .opacity(logoHidden ? 0 : (entered ? 1 : 0))

            // Disclaimer slides into the same centered position the
            // logo just vacated. Only mounted while needed so the
            // @State-driven entry animation fires fresh.
            if showDisclaimer {
                DisclaimerView(onAcknowledge: onAcknowledgeDisclaimer)
                    // Fully fade during the final exit so the whole
                    // splash collapses cleanly.
                    .opacity(exiting ? 0 : 1)
                    .scaleEffect(exiting ? 0.95 : 1)
                    .blur(radius: exiting ? 10 : 0)
            }
        }
        .onAppear {
            withAnimation(Motion.gentle) {
                entered = true
            }
        }
    }
}


private struct PixelDitherPattern: View {
    let color: Color

    private let cellSize: CGFloat = 14
    private let scale: CGFloat = 5

    private var tileWidth: CGFloat { cellSize * 3 }
    private var tileHeight: CGFloat { cellSize * 2 }

    nonisolated(unsafe) private static let cachedTileImage: UIImage = {
        let tileW: CGFloat = 14 * 3
        let tileH: CGFloat = 14 * 2
        let uiColor = UIColor.white.withAlphaComponent(0.08)
        let size = CGSize(width: tileW, height: tileH)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            uiColor.setFill()
            drawCircle(ctx, ox: 2, oy: 2)
            drawCross(ctx, ox: 16, oy: 2)
            drawDiamond(ctx, ox: 30, oy: 2)
            drawDiamond(ctx, ox: 2, oy: 16)
            drawCircle(ctx, ox: 16, oy: 16)
            drawCross(ctx, ox: 30, oy: 16)
        }
    }()

    var body: some View {
        // TimelineView drives Canvas with the system's display link,
        // so the pattern pauses automatically when the scene is
        // inactive. No manual Task.sleep loop or phase @State.
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate / SplashTiming.cycleDuration
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                guard let cg = ctx.resolveSymbol(id: 0) else { return }

                let scaledTileW = tileWidth * scale
                let scaledTileH = tileHeight * scale
                let dx = CGFloat(phase.truncatingRemainder(dividingBy: 1.0)) * scaledTileW

                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: .degrees(-15))

                let coverage = max(size.width, size.height) * 1.6
                let startX = -coverage - scaledTileW + dx.truncatingRemainder(dividingBy: scaledTileW)
                let startY = -coverage

                var y = startY
                while y < coverage {
                    var x = startX
                    while x < coverage {
                        ctx.draw(cg, in: CGRect(x: x, y: y, width: scaledTileW, height: scaledTileH))
                        x += scaledTileW
                    }
                    y += scaledTileH
                }
            } symbols: {
                Image(uiImage: Self.cachedTileImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: tileWidth * scale, height: tileHeight * scale)
                    .tag(0)
            }
        }
    }

    // 10px circle - smooth pixel art rounding
    private static func drawCircle(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
        let rows: [(x: CGFloat, w: CGFloat)] = [
            (3, 4), (2, 6), (1, 8), (1, 8), (0, 10),
            (0, 10), (1, 8), (1, 8), (2, 6), (3, 4),
        ]
        for (i, row) in rows.enumerated() {
            ctx.fill(CGRect(x: ox + row.x, y: oy + CGFloat(i), width: row.w, height: 1))
        }
    }

    // 10px bold X - 3px-wide strokes, rounded single-pixel tips
    private static func drawCross(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
        let rects: [(x: CGFloat, y: CGFloat, w: CGFloat)] = [
            (1, 0, 1), (8, 0, 1),
            (0, 1, 3), (7, 1, 3),
            (1, 2, 3), (6, 2, 3),
            (2, 3, 3), (5, 3, 3),
            (3, 4, 4),
            (3, 5, 4),
            (2, 6, 3), (5, 6, 3),
            (1, 7, 3), (6, 7, 3),
            (0, 8, 3), (7, 8, 3),
            (1, 9, 1), (8, 9, 1),
        ]
        for r in rects {
            ctx.fill(CGRect(x: ox + r.x, y: oy + r.y, width: r.w, height: 1))
        }
    }

    // 10px diamond - pointed rhombus
    private static func drawDiamond(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
        let rows: [(x: CGFloat, w: CGFloat)] = [
            (4, 2), (3, 4), (2, 6), (1, 8), (0, 10),
            (0, 10), (1, 8), (2, 6), (3, 4), (4, 2),
        ]
        for (i, row) in rows.enumerated() {
            ctx.fill(CGRect(x: ox + row.x, y: oy + CGFloat(i), width: row.w, height: 1))
        }
    }
}
