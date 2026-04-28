import SwiftUI

private enum SplashTiming {
    static let holdDuration: TimeInterval = 1.2
    static let cycleDuration: TimeInterval = 3
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
        .alert(
            engineHung ? "Restart Empo" : "Something went wrong",
            isPresented: showErrorAlert
        ) {
            Button("OK") {
                if engineHung {
                    // RGSS thread is still running inside a script that
                    // never yielded to checkShutdown(). The Ruby VM
                    // cannot be respawned in-place, but per App Store
                    // guideline 2.5.1 we don't quit programmatically.
                    // Dismiss the alert; the user closes Empo from the
                    // app switcher and reopens it.
                    appState.errorMessage = nil
                    return
                }
                if appState.phase != nil {
                    appState.returnToLibrary()
                } else {
                    appState.dismissCrashRecovery()
                }
            }
        } message: {
            if engineHung {
                Text("The game stopped responding. Close Empo and reopen it.")
            } else {
                Text(appState.errorMessage ?? "")
            }
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

    /// True when the RGSS thread didn't ack a termination request in
    /// time, leaving Ruby in an unrecoverable state. The single-thread
    /// engine architecture can't respawn the VM in-place, so the only
    /// way out is for the user to close + reopen the app manually
    /// (we don't call `exit()` per App Store guideline 2.5.1).
    private var engineHung: Bool {
        mkxp_isEngineHung() != 0
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

    // Tile geometry: 16x16 SVG icons in a 3-col x 2-row grid with
    // a 4pt gutter on every edge and between cells. Total tile
    // dimensions follow `cells*size + (cells+1)*gutter`.
    private static let iconSize: CGFloat = 16
    private static let iconCols = 3
    private static let iconRows = 2
    private static let iconGutter: CGFloat = 4
    private static let scale: CGFloat = 5

    private static let tileWidth: CGFloat =
        iconSize * CGFloat(iconCols) + iconGutter * CGFloat(iconCols + 1)
    private static let tileHeight: CGFloat =
        iconSize * CGFloat(iconRows) + iconGutter * CGFloat(iconRows + 1)

    /// Tile rasterized lazily on first splash render: pick six
    /// random icons from the curated 16x16 SVG pack
    /// (`Assets.bundle/SplashIcons/`), parse each via the
    /// in-process `SplashIcons.path(for:)` parser, and stamp them
    /// into the tile in row-major order. Background stays
    /// transparent so the splash's `Color.brand` shows through;
    /// the fill color is white-with-low-alpha to match the prior
    /// "subtle pattern over the brand color" visual. Tile content
    /// changes between launches (icons are picked anew on each
    /// process start) but stays static within a session - the
    /// panning Canvas reuses this single image.
    nonisolated(unsafe) private static let cachedTileImage: UIImage = {
        let size = CGSize(width: tileWidth, height: tileHeight)
        let uiColor = UIColor.white.withAlphaComponent(0.08)
        let names = SplashIcons.randomNames(count: iconCols * iconRows)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            uiColor.setFill()
            var iter = names.makeIterator()
            for row in 0..<iconRows {
                for col in 0..<iconCols {
                    guard let name = iter.next(),
                          let path = SplashIcons.path(for: name)
                    else { continue }
                    let x = iconGutter + CGFloat(col) * (iconSize + iconGutter)
                    let y = iconGutter + CGFloat(row) * (iconSize + iconGutter)
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: x, y: y)
                    path.fill()
                    ctx.cgContext.restoreGState()
                }
            }
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

                let scaledTileW = Self.tileWidth * Self.scale
                let scaledTileH = Self.tileHeight * Self.scale
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
                    .frame(width: Self.tileWidth * Self.scale,
                           height: Self.tileHeight * Self.scale)
                    .tag(0)
            }
        }
    }
}
