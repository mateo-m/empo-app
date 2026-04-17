import SwiftUI

struct RootView: View {
    private let appState = AppState.shared
    private let engineState = EngineState.shared
    private let layout = ControlsLayout.shared
    private let settings = AppSettings.shared
    @Namespace private var hero
    @State private var showSplash = !AppState.shared.pendingCrashRecovery
    @State private var splashExiting = false
    @State private var splashDismissed = AppState.shared.pendingCrashRecovery

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
                SplashView(exiting: splashExiting)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if settings.rendererPendingRestart, PauseManager.shared.pausedGame != nil {
                RendererRestartPill(to: settings.renderer)
                    .transition(
                        .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .modifier(
                            active: BlurModifier(radius: 8),
                            identity: BlurModifier(radius: 0)
                        ))
                    )
                    .padding(.bottom, Spacing.xl)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0), value: settings.rendererPendingRestart)
        .animation(.spring(duration: 0.35, bounce: 0), value: PauseManager.shared.pausedGame == nil)
        .onAppear {
            if appState.pendingCrashRecovery {
                appState.consumeCrashRecovery()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                splashDismissed = true
                withAnimation(.spring(duration: 0.5, bounce: 0)) {
                    splashExiting = true
                } completion: {
                    showSplash = false
                    appState.consumeCrashRecovery()
                }
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
}


private struct RendererRestartPill: View {
    let to: RendererOption

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))

            Text("\(to.label) will kick in once you quit the current game")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.brand.opacity(0.9), in: Capsule())
        .foregroundStyle(.white)
        .elevatedShadow()
        .animation(.spring(duration: 0.3, bounce: 0), value: to)
    }
}


private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}


private struct SplashView: View {
    let exiting: Bool
    @State private var entered = false

    var body: some View {
        ZStack {
            Color.brand
                .ignoresSafeArea()
                .opacity(exiting ? 0 : 1)

            PixelDitherPattern(color: .white)
                .ignoresSafeArea()
                .opacity(exiting ? 0 : 1)

            VStack(spacing: Spacing.lg) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.white)
                    .blur(radius: exiting ? 10 : 0)
                    .scaleEffect(exiting ? 0.8 : 1)
                    .opacity(exiting ? 0 : 1)

                Text("mkxp-z")
                    .font(.title)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .foregroundStyle(.white)
                    .blur(radius: exiting ? 10 : 0)
                    .scaleEffect(exiting ? 0.8 : 1)
                    .opacity(exiting ? 0 : 1)
            }
            .scaleEffect(entered ? 1 : 0.8)
            .opacity(entered ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.35, bounce: 0)) {
                entered = true
            }
        }
    }
}


private struct PixelDitherPattern: View {
    let color: Color
    private let cellSize: CGFloat = 14
    private let scale: CGFloat = 5

    @State private var panning = false

    private var tileWidth: CGFloat { cellSize * 3 }
    private var tileHeight: CGFloat { cellSize * 2 }

    private var tileImage: UIImage {
        let uiColor = UIColor(color).withAlphaComponent(0.08)
        let size = CGSize(width: tileWidth, height: tileHeight)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            uiColor.setFill()

            // Row 0: circle, cross, diamond
            drawCircle(ctx, ox: 2, oy: 2)
            drawCross(ctx, ox: 16, oy: 2)
            drawDiamond(ctx, ox: 30, oy: 2)

            // Row 1 (rotated order): diamond, circle, cross
            drawDiamond(ctx, ox: 2, oy: 16)
            drawCircle(ctx, ox: 16, oy: 16)
            drawCross(ctx, ox: 30, oy: 16)
        }
    }

    var body: some View {
        Image(uiImage: tileImage)
            .interpolation(.none)
            .resizable(resizingMode: .tile)
            .scaleEffect(scale)
            .rotationEffect(.degrees(-15))
            .offset(x: panning ? tileWidth * scale : 0, y: panning ? -tileHeight * scale * 0.5 : 0)
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    panning = true
                }
            }
    }

    // 10px circle — smooth pixel art rounding
    private func drawCircle(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
        let rows: [(x: CGFloat, w: CGFloat)] = [
            (3, 4), (2, 6), (1, 8), (1, 8), (0, 10),
            (0, 10), (1, 8), (1, 8), (2, 6), (3, 4),
        ]
        for (i, row) in rows.enumerated() {
            ctx.fill(CGRect(x: ox + row.x, y: oy + CGFloat(i), width: row.w, height: 1))
        }
    }

    // 10px bold X — 3px-wide strokes, rounded single-pixel tips
    private func drawCross(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
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

    // 10px diamond — pointed rhombus
    private func drawDiamond(_ ctx: UIGraphicsImageRendererContext, ox: CGFloat, oy: CGFloat) {
        let rows: [(x: CGFloat, w: CGFloat)] = [
            (4, 2), (3, 4), (2, 6), (1, 8), (0, 10),
            (0, 10), (1, 8), (2, 6), (3, 4), (4, 2),
        ]
        for (i, row) in rows.enumerated() {
            ctx.fill(CGRect(x: ox + row.x, y: oy + CGFloat(i), width: row.w, height: 1))
        }
    }
}
