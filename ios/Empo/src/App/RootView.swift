import SwiftUI

private enum SplashTiming {
    static let holdDuration: TimeInterval = 1.2
    /// Extra time after the hold. It keeps the splash up while the
    /// initial library scan finishes, so dismissal never reveals an
    /// in-between library (blank, or empty-state-then-snap). The cap
    /// makes sure a pathological scan cannot hold the splash
    /// forever. Past the cap, the library's own pre-scan blank state
    /// takes over.
    static let scanGraceDuration: TimeInterval = 2.5
    static let cycleDuration: TimeInterval = 3
}

struct RootView: View {
    @Environment(\.appState) private var appState
    @Environment(\.engineState) private var engineState
    @Environment(\.controlsLayout) private var layout
    @Environment(\.appSettings) private var settings
    @Environment(\.gameLibrary) private var library
    @Namespace private var hero
    @State private var showSplash: Bool
    @State private var splashExiting = false
    @State private var splashDismissed: Bool
    /// The library stays mounted through the loading→playing fade.
    /// It then unmounts, so Ken Burns / NavigationStack stop
    /// compositing over the embedded game view.
    @State private var libraryMounted = true

    init() {
        let recovering = AppState.shared.pendingCrashRecovery
        _showSplash = State(initialValue: !recovering)
        _splashDismissed = State(initialValue: recovering)
    }
    /// When true, the splash logo cross-fades out and the disclaimer
    /// cross-fades in on top of the same orange background. The flow
    /// flips it at the 1.2s mark, and only when the user has not
    /// acknowledged yet.
    @State private var showDisclaimer = false

    var body: some View {
        ZStack {
            // Explicit transparent base. Without this, SwiftUI can
            // default the UIHostingController backdrop to
            // systemBackground, which occludes the SDL window on
            // device even when every child view is "clear".
            Color.clear.ignoresSafeArea()

            // Fade the library out on play (loading banner handoff).
            // Then unmount after the spring, so Ken Burns /
            // NavigationStack do not keep running over the embedded
            // game view. Remounts on pause/return. GameLibraryView
            // clears the path.
            if libraryMounted {
                GameLibraryView(heroNamespace: hero, splashDismissed: splashDismissed)
                    .opacity(appState.phase == .playing ? 0 : 1)
                    .allowsHitTesting(appState.phase != .playing)
                    .transition(.identity)
            }

            // Instant appear: the library fades out underneath without
            // a cross-fade dim on the controls.
            if appState.phase == .playing {
                PlayerView(appState: appState, engineState: engineState, layout: layout)
                    .transition(.identity)
                    .allowsHitTesting(
                        appState.errorMessage == nil && appState.infoMessage == nil
                    )
            }
        }
        .fontDesign(.rounded)
        .tint(.brand)
        .onChange(of: appState.phase) { _, phase in
            if phase == .playing {
                // Slightly longer than GameLoadingView's handoff spring
                // (0.15–0.30s) so the fade finishes before unmount.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard appState.phase == .playing else { return }
                    libraryMounted = false
                }
            } else {
                libraryMounted = true
            }
        }
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
            await appState.checkForUpdatesIfStale()
        }
        .task {
            if appState.pendingCrashRecovery {
                appState.consumeCrashRecovery()
                return
            }
            // Hold the splash visible for ~1.2s before the transition
            // to either the disclaimer (first launch) or the library.
            // .task cancels on disappear. If the view goes away early,
            // the sleep unwinds cleanly.
            try? await Task.sleep(for: .milliseconds(Int(SplashTiming.holdDuration * 1000)))
            if settings.needsDisclaimer {
                // Hold the splash open: fade the logo out (enter the
                // "exiting" visual, but do not dismiss the container)
                // and reveal the disclaimer. The normal dismissal
                // runs once the user acknowledges. No scan gating
                // here. The disclaimer read time dwarfs the scan, and
                // the library's pre-scan blank state covers the
                // residual case.
                withAnimation(Motion.gentle) {
                    showDisclaimer = true
                }
            } else {
                await waitForInitialLibraryScan()
                dismissSplash()
            }
        }
        .alert(
            errorAlertTitle,
            isPresented: showErrorAlert
        ) {
            Button("OK") {
                dismissErrorAlert()
                if engineHung {
                    return
                }
                if appState.phase != nil {
                    // A session that already terminated (clean exit
                    // with a parting message, or a crash) drops back
                    // to the library here when cross-session play is
                    // on. Mid-game errors (engine still running)
                    // no-op inside and keep the session up.
                    appState.finishEndedSession()
                    return
                }
                appState.dismissCrashRecovery()
            }
        } message: {
            if engineHung {
                Text("The game stopped responding. Close Empo and reopen it.")
            } else if CrossSessionPolicy.appendsForceCloseGuidance(
                engineHung: engineHung,
                phaseActive: appState.phase != nil,
                sessionEndedBehindAlert: sessionEndedBehindAlert)
            {
                Text(
                    "\(appState.errorMessage ?? "An error occurred.") Close Empo from the app switcher and reopen it to continue."
                )
            } else {
                Text(appState.errorMessage ?? "")
            }
        }
        .alert(
            infoAlertTitle,
            isPresented: showInfoAlert
        ) {
            Button("OK") {
                dismissInfoAlert()
            }
        } message: {
            Text(appState.infoMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) {
            _ in
            if appState.phase == .playing {
                engineState.requestBackgroundPause()
                // If the engine rendered at least one frame, this was a
                // healthy session. Remove the crash marker, so a
                // force-kill from the app switcher does not trigger a
                // false crash alert. Black-screen crashes leave
                // engineReady false, so the marker persists and the
                // alert still fires.
                if appState.engineReady {
                    appState.clearCrashMarkerForBackground()
                }
            }
            // Persist play time when the app backgrounds, so a
            // force-kill from the switcher does not lose the session.
            // No-op when the timer already flushed (e.g. the user
            // paused to the library).
            appState.flushSessionPlayTimeForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) {
            _ in
            if appState.phase == .playing {
                engineState.resumeFromBackground()
                // Re-create the crash marker, so the next launch still
                // detects a crash after resume.
                appState.restoreCrashMarkerForForeground()
                appState.resumeSessionTimingAfterBackground()
            }
        }
        .onChange(of: appState.errorMessage) { _, message in
            if message != nil {
                AppWindow.setAllowKeyWindow(true)
            } else if appState.phase == .playing, appState.infoMessage == nil {
                AppWindow.setAllowKeyWindow(false)
            } else if appState.phase != .playing, appState.infoMessage == nil {
                AppWindow.setAllowKeyWindow(false)
            }
        }
        .onChange(of: appState.infoMessage) { _, message in
            if message != nil {
                AppWindow.setAllowKeyWindow(true)
            } else if appState.phase == .playing, appState.errorMessage == nil {
                AppWindow.setAllowKeyWindow(false)
            } else if appState.phase != .playing, appState.errorMessage == nil {
                AppWindow.setAllowKeyWindow(false)
            }
        }
    }

    private var showErrorAlert: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { dismissErrorAlert() } }
        )
    }

    /// Unblocks any engine thread waiting in `mkxp_presentErrorAndWait()`.
    private func dismissErrorAlert() {
        mkxp_signalErrorDismissed()
        appState.errorMessage = nil
    }

    private var showInfoAlert: Binding<Bool> {
        Binding(
            get: { appState.infoMessage != nil },
            set: { if !$0 { dismissInfoAlert() } }
        )
    }

    /// The game speaks in its own name. Title the alert after the
    /// running game, so the notice does not read as an Empo message.
    private var infoAlertTitle: String {
        appState.selectedGame?.title
            ?? PauseManager.shared.pausedGame?.title
            ?? "Message"
    }

    /// Unblocks the engine thread that waits in `mkxp_presentInfoAndWait()`.
    /// The game resumes right where it called `msgbox`.
    private func dismissInfoAlert() {
        mkxp_signalInfoDismissed()
        appState.infoMessage = nil
    }

    /// True when the RGSS thread did not ack a termination request in
    /// time. Ruby is then in an unrecoverable state. The single-thread
    /// engine architecture cannot respawn the VM in place, so the only
    /// way out is for the user to close and reopen the app manually.
    /// We do not call `exit()`, per App Store guideline 2.5.1.
    private var engineHung: Bool {
        mkxp_isEngineHung() != 0
    }

    /// True when an error alert presents over a session whose engine
    /// terminated recoverably: parked in the session loop, not hung,
    /// no Ruby instance stranded by a crash. The OK button then
    /// returns to the library (finishEndedSession), so the message
    /// must not tell the user to force-close the app. A crash that
    /// stranded its instance is NOT recoverable - every next launch
    /// would be blocked - so it keeps the restart framing. Decision
    /// logic in CrossSessionPolicy (unit-tested); live inputs here.
    private var sessionEndedBehindAlert: Bool {
        CrossSessionPolicy.sessionEndedBehindAlert(
            enabled: CrossSessionPlay.enabled,
            recoverable: mkxp_isSessionRecoverable() != 0
        )
    }

    private var errorAlertTitle: String {
        CrossSessionPolicy.errorAlertTitle(
            engineHung: engineHung,
            phaseActive: appState.phase != nil,
            sessionEndedBehindAlert: sessionEndedBehindAlert,
            cleanExit: mkxp_didEngineExitCleanly() != 0
        )
    }

    /// Wait (up to `scanGraceDuration`) for the initial library scan.
    /// The splash then lifts on a settled library instead of a blank
    /// or soon-to-snap one. A 50ms poll is invisible at splash
    /// timescales and avoids continuation plumbing through
    /// GameLibrary. Bails out early when the hosting `.task` cancels.
    private func waitForInitialLibraryScan() async {
        let deadline = ContinuousClock.now + .seconds(SplashTiming.scanGraceDuration)
        while !library.initialScanCompleted,
            ContinuousClock.now < deadline,
            !Task.isCancelled
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Normal splash exit: fade the background, the logo, and any
    /// disclaimer still on screen. Then unmount the splash overlay.
    private func dismissSplash() {
        splashDismissed = true
        withAnimation(Motion.slow) {
            splashExiting = true
        } completion: {
            showSplash = false
            appState.consumeCrashRecovery()
        }
    }

    /// The disclaimer's "I understand" button calls this. It persists
    /// the acknowledgment and runs the usual splash exit animation.
    private func acknowledgeAndDismissSplash() {
        settings.acknowledgeDisclaimer()
        dismissSplash()
    }
}

private struct SplashView: View {
    /// True when the whole splash animates out (fades the background
    /// and all content on top of it). This is the final exit phase.
    let exiting: Bool
    /// True when the disclaimer has taken over. The logo then fades
    /// out and the disclaimer fades in. The splash stays mounted.
    let showDisclaimer: Bool
    let onAcknowledgeDisclaimer: () -> Void

    @State private var entered = false

    /// Combined "logo should be visually absent" flag. True during the
    /// disclaimer phase OR during the full exit. It stays one variable
    /// so the same fade/scale/blur treatment drives both.
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
            VStack(spacing: Spacing.xl) {
                Image(.empoMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.white)
                Text(AppInfo.name)
                    .font(AppFont.wordmark)
                    .foregroundStyle(.white)
            }
            .blur(radius: logoHidden ? 10 : 0)
            .scaleEffect(logoHidden ? 0.8 : (entered ? 1 : 0.8))
            .opacity(logoHidden ? 0 : (entered ? 1 : 0))

            // The disclaimer slides into the same centered position
            // the logo just left. It mounts only while needed, so the
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

    /// The tile rasterizes lazily on the first splash render: pick
    /// six random icons from the curated 16x16 SVG pack
    /// (`Assets.bundle/SplashIcons/`), parse each via the
    /// in-process `SplashIcons.path(for:)` parser, and stamp them
    /// into the tile in row-major order. The background stays
    /// transparent, so the splash's `Color.brand` shows through.
    /// The fill color is white with low alpha, to match the prior
    /// "subtle pattern over the brand color" visual. Tile content
    /// changes between launches (each process start picks new
    /// icons) but stays static within a session. The panning
    /// Canvas reuses this single image.
    nonisolated private static let cachedTileImage: UIImage = {
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
                    .frame(
                        width: Self.tileWidth * Self.scale,
                        height: Self.tileHeight * Self.scale
                    )
                    .tag(0)
            }
        }
    }
}
