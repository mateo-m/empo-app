import SwiftUI


/// Preference key used by the overlay to report its measured height
/// back to PlayerView, so the draggable clamp math matches whatever
/// size the content actually settles at (long titles / wrapped lines
/// make the overlay taller than the fixed-height guess).
struct DebugOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


/// Observable state backing `DebugOverlayView`. Kept in the player
/// view as a long-lived property so the overlay can be
/// transitioned in and out (via `if showDebugOverlay { ... }`)
/// without losing its FPS graph, cached game title, or RGSS version.
@MainActor @Observable
final class DebugOverlayState {
    var fps: Double = 0
    var gameTitle: String = "--"
    var rgssVersion: Int32 = 0
    var ringBuffer = FPSRingBuffer(capacity: 120)
    var metadataLoaded = false
}


struct DebugOverlayView: View {
    let state: DebugOverlayState
    private let maxFPS: Double = 70

    // Local aliases so the existing view body stays legible.
    private var fps: Double { state.fps }
    private var gameTitle: String { state.gameTitle }
    private var rgssVersion: Int32 { state.rgssVersion }
    private var ringBuffer: FPSRingBuffer { state.ringBuffer }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            gameTitleBlock

            debugText(rubyLine)
            debugText(rendererLine)

            if let device = metalDeviceLine {
                debugText(device)
            }

            debugText(
                mkxp_isGameReady() != 0 ? "Running" : "Loading\u{2026}",
                color: mkxp_isGameReady() != 0 ? .success : .warning
            )

            HStack(spacing: Spacing.xs) {
                Text("\(Int(fps.rounded())) FPS")
                    .font(AppFont.debugFPS)
                    .foregroundStyle(fpsColor)

                // FPS Graph. Canvas has no intrinsic content size;
                // constrained to a fixed height; otherwise it grabs every
                // available point and bloats the overlay vertically.
                Canvas { context, size in
                    let samples = ringBuffer.samples
                    guard samples.count >= 2 else { return }
                    var path = Path()
                    for (i, sample) in samples.enumerated() {
                        let x = CGFloat(i) / CGFloat(ringBuffer.capacity - 1) * size.width
                        let y = size.height - (sample / maxFPS) * size.height
                        let clamped = max(0, min(size.height, y))
                        if i == 0 { path.move(to: CGPoint(x: x, y: clamped)) }
                        else { path.addLine(to: CGPoint(x: x, y: clamped)) }
                    }
                    context.stroke(path, with: .color(fpsColor), lineWidth: 1.5)
                }
                .frame(height: 28)
            }
        }
        .padding(Spacing.md + Spacing.xxs)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.sm + Spacing.xxs))
        .darkGlass()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DebugOverlayHeightKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard mkxp_isEngineTerminated() == 0 else { return }
            state.fps = mkxp_getAverageFPS()
            state.ringBuffer.append(state.fps)

            if !state.metadataLoaded {
                state.rgssVersion = mkxp_getRGSSVersion()
                if let title = mkxp_getGameTitle(), title[0] != 0 {
                    state.gameTitle = String(cString: title)
                    state.metadataLoaded = true
                }
            }
        }
    }

    private var fpsColor: Color {
        if fps >= 55 { return .success }
        if fps >= 30 { return .warning }
        return .destructive
    }

    /// Monospaced text row with the overlay's default styling. Wraps
    /// to additional lines when the content exceeds the overlay's
    /// fixed width instead of truncating. Font defaults to
    /// `AppFont.debugBody`; callers that need a bigger/bolder
    /// variant (e.g. the title line) pass the corresponding token.
    @ViewBuilder
    private func debugText(
        _ text: String,
        font: Font = AppFont.debugBody,
        color: Color = .white.opacity(Alpha.textMuted)
    ) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Game title with the RGSS version next to it when it fits on one
    /// line (separated by a middle-dot), or stacked on a second line
    /// when it doesn't. ViewThatFits picks the first child whose
    /// measured size is <= the proposed width; the single-line variant
    /// is listed first and falls back to the two-row variant if the
    /// overlay's 220pt width can't hold the full title + dot + RGSS.
    @ViewBuilder
    private var gameTitleBlock: some View {
        if rgssVersion > 0 {
            ViewThatFits(in: .horizontal) {
                debugText(
                    "\(gameTitle) \u{00B7} RGSS\(rgssVersion)",
                    font: AppFont.debugTitle, color: .white
                )
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    debugText(gameTitle, font: AppFont.debugTitle, color: .white)
                    debugText("RGSS\(rgssVersion)", font: AppFont.debugTitle, color: .white)
                }
            }
        } else {
            debugText(gameTitle, font: AppFont.debugTitle, color: .white)
        }
    }

    private var rubyLine: String {
        "Ruby \(String(cString: mkxp_getRubyVersion()))"
    }

    /// Renderer line. Shows the ANGLE version once GL has initialized;
    /// falls back to `ANGLE (Metal)` before then.
    private var rendererLine: String {
        let version = String(cString: mkxp_getANGLEVersion())
        if version == "unknown" {
            return "ANGLE (Metal)"
        }
        return "ANGLE \(version) (Metal)"
    }

    /// Metal device line. Hidden (returns nil) until GL has initialized.
    private var metalDeviceLine: String? {
        let device = String(cString: mkxp_getMetalDeviceName())
        return device == "unknown" ? nil : device
    }
}


struct FPSRingBuffer {
    let capacity: Int
    private var buffer: [Double]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Double](repeating: 0, count: capacity)
    }

    mutating func append(_ value: Double) {
        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Returns samples in chronological order (oldest first).
    var samples: [Double] {
        if count < capacity {
            return Array(buffer[0..<count])
        }
        // Ring wrapped: oldest is at writeIndex, read to end then wrap
        return Array(buffer[writeIndex..<capacity]) + Array(buffer[0..<writeIndex])
    }
}
