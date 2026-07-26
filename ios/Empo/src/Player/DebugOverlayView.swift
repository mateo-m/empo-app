import SwiftUI

/// Preference key the overlay uses to report its measured height
/// back to PlayerView, so the draggable clamp math matches whatever
/// size the content settles at (long titles / wrapped lines
/// make the overlay taller than the fixed-height guess).
struct DebugOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Observable state that backs `DebugOverlayView`. It lives in the
/// player view as a long-lived property so the overlay can transition
/// in and out (via `if showDebugOverlay { ... }`) without loss of its
/// FPS graph, cached game title, or RGSS version.
@MainActor @Observable
final class DebugOverlayState {
    var fps: Double = 0
    var gameTitle: String = "--"
    var rgssVersion: Int32 = 0
    var ringBuffer = FPSRingBuffer(capacity: 120)
    var metadataLoaded = false
    /// Resident memory in MB (phys_footprint via task_vm_info, the
    /// same number Xcode's memory gauge and the App Store "Memory"
    /// stat show). 0 when the query isn't available yet or fails
    /// (e.g. sandboxed variant that denies the mach port). It
    /// refreshes on the same 10Hz tick as FPS, so we can watch a
    /// number that grows over time and spot leaks from the compat
    /// layer without Instruments.
    var memoryMB: Double = 0
    /// Rolling memory samples for the overlay's mini-graph. Same
    /// capacity as the FPS buffer so the two line charts stay
    /// visually aligned.
    var memoryBuffer = FPSRingBuffer(capacity: 120)
}

struct DebugOverlayView: View {
    let state: DebugOverlayState
    private let maxFPS: Double = 70

    // Local aliases so the existing view body stays legible.
    private var fps: Double { state.fps }
    private var gameTitle: String { state.gameTitle }
    private var rgssVersion: Int32 { state.rgssVersion }
    private var ringBuffer: FPSRingBuffer { state.ringBuffer }
    private var memoryMB: Double { state.memoryMB }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            gameTitleBlock

            debugText(rubyLine)
            if let line = rubyInstanceLine {
                debugText(line)
            }
            if let line = syntaxTransformLine {
                debugText(line)
            }
            debugText(rendererLine)

            if let device = metalDeviceLine {
                debugText(device)
            }

            debugText(
                mkxp_isGameReady() != 0 ? "Running" : "Loading\u{2026}",
                color: mkxp_isGameReady() != 0 ? .success : .warning
            )

            memoryRow

            HStack(spacing: Spacing.xs) {
                Text("\(Int(fps.rounded())) FPS")
                    .font(AppFont.debugFPS)
                    .monospacedDigit()
                    .foregroundStyle(fpsColor)
                    .frame(width: 90, alignment: .leading)

                // FPS Graph. Canvas has no intrinsic content size, so
                // we constrain it to a fixed height. Otherwise it grabs
                // every available point and bloats the overlay
                // vertically.
                Canvas { context, size in
                    let samples = ringBuffer.samples
                    guard samples.count >= 2 else { return }
                    var path = Path()
                    for (i, sample) in samples.enumerated() {
                        let x = CGFloat(i) / CGFloat(ringBuffer.capacity - 1) * size.width
                        let y = size.height - (sample / maxFPS) * size.height
                        let clamped = max(0, min(size.height, y))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: clamped))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: clamped))
                        }
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
            state.memoryMB = Self.currentMemoryMB()
            if state.memoryMB > 0 {
                state.memoryBuffer.append(state.memoryMB)
            }

            if !state.metadataLoaded {
                state.rgssVersion = mkxp_getRGSSVersion()
                if let title = mkxp_getGameTitle(), title[0] != 0 {
                    state.gameTitle = String(cString: title)
                    state.metadataLoaded = true
                }
            }
        }
    }

    /// Row that mirrors the FPS row layout: left-aligned label,
    /// right-flexible graph. The graph autoscales between the
    /// minimum and maximum seen values, so small growth stays
    /// visible even as the baseline increases. That makes leak
    /// trends easy to spot.
    @ViewBuilder
    private var memoryRow: some View {
        HStack(spacing: Spacing.xs) {
            // Fixed-width slot with monospaced digits so digit-count
            // changes (e.g. 99 MB -> 100 MB) don't nudge the graph
            // left/right mid-session.
            Text(memoryLine)
                .font(AppFont.debugBody)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(Alpha.textMuted))
                .frame(width: 90, alignment: .leading)

            Canvas { context, size in
                let samples = state.memoryBuffer.samples
                guard samples.count >= 2 else { return }
                let lo = samples.min() ?? 0
                let hi = samples.max() ?? 0
                // Guard against a flat line collapsing the graph to
                // a vertical bar: pad the range so it visibly
                // occupies the canvas.
                let range = max(hi - lo, 1)
                var path = Path()
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) / CGFloat(state.memoryBuffer.capacity - 1) * size.width
                    let y = size.height - ((sample - lo) / range) * size.height
                    let clamped = max(0, min(size.height, y))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: clamped))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: clamped))
                    }
                }
                context.stroke(path, with: .color(.white.opacity(Alpha.textMuted)), lineWidth: 1.5)
            }
            .frame(height: 28)
        }
    }

    /// App-level memory footprint in MB. Uses `phys_footprint` from
    /// task_vm_info, which is the same number Xcode's memory gauge
    /// reports and what Apple uses to decide jetsam pressure.
    /// Returns 0 on failure (query denied, sandboxed variant).
    private static func currentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    /// Memory line. Shows "--" while the first sample settles, then
    /// the current footprint.
    private var memoryLine: String {
        if memoryMB <= 0 {
            return "Memory --"
        }
        return String(format: "Memory %.0f MB", memoryMB)
    }

    private var fpsColor: Color {
        if fps >= 55 { return .success }
        if fps >= 30 { return .warning }
        return .destructive
    }

    /// Monospaced text row with the overlay's default styling. Wraps
    /// to more lines when the content exceeds the overlay's fixed
    /// width instead of truncating. The font defaults to
    /// `AppFont.debugBody`. Callers that need a bigger or bolder
    /// variant (e.g. the title line) pass the matching token.
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
    /// line (a middle-dot separates them), or stacked on a second line
    /// when it doesn't. ViewThatFits picks the first child whose
    /// measured size is <= the proposed width. The single-line variant
    /// comes first, and the two-row variant takes over when the
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

    /// Cross-session play: which island instance this session runs
    /// on and via which freshness mechanism (canonical dlopen,
    /// reset-in-place, copy-and-load, or the single-shot static
    /// fallback). This is the field view of the instance manager's
    /// unload canary — the on-device answer to "does dlclose
    /// actually unload our islands". Hidden while the flag is off.
    private var rubyInstanceLine: String? {
        guard CrossSessionPlay.enabled else { return nil }
        return String(cString: mkxp_getRubyInstanceDiagnostics())
    }

    /// Reports the active syntax-transform mode set via
    /// `mkxp_setSyntaxTransformMode`. The transforms only take
    /// effect on the patched Ruby 3.1 parser. On the Ruby
    /// 1.8 / 1.9 / 3.0 builds the value is a no-op, so we hide
    /// the line. Returns nil when the mode hasn't been set or
    /// when the active interpreter doesn't honor the patches.
    private var syntaxTransformLine: String? {
        let rubyTag = String(cString: mkxp_getRubyVersion())
        guard rubyTag.hasPrefix("3.1") else { return nil }
        switch mkxp_getSyntaxTransformMode() {
        case MKXP_SYNTAX_TRANSFORM_LEGACY: return "Compatibility: legacy"
        case MKXP_SYNTAX_TRANSFORM_DISABLED: return "Compatibility: modern"
        case MKXP_SYNTAX_TRANSFORM_CUSTOM: return "Compatibility: custom"
        default: return nil
        }
    }

    /// Renderer line. Shows the ANGLE version once GL has initialized.
    /// Falls back to `ANGLE (Metal)` before then.
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
