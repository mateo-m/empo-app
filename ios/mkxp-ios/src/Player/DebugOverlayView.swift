import SwiftUI

// MARK: - Debug Overlay

struct DebugOverlayView: View {
    @State private var fps: Double = 0
    @State private var gameTitle: String = "--"
    @State private var rgssVersion: Int32 = 0
    @State private var ringBuffer = FPSRingBuffer(capacity: 120)
    @State private var metadataLoaded = false
    private let maxFPS: Double = 70

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(gameTitle)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text(rgssVersion > 0 ? "Ruby 1.8 \u{00B7} RGSS\(rgssVersion)" : "Ruby 1.8")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            Text(mkxp_isGameReady() != 0 ? "Running" : "Loading\u{2026}")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(mkxp_isGameReady() != 0 ? .success : .warning)

            HStack(spacing: Spacing.xs) {
                Text("\(Int(fps.rounded())) FPS")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(fpsColor)

                // FPS Graph
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
            }
        }
        .padding(Spacing.md + Spacing.xxs)
        .background(Color.black.opacity(Overlay.medium + 0.05))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm + Spacing.xxs))
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard mkxp_isEngineTerminated() == 0 else { return }
            fps = mkxp_getAverageFPS()
            ringBuffer.append(fps)

            // Load once — title/version don't change mid-session
            if !metadataLoaded {
                rgssVersion = mkxp_getRGSSVersion()
                if let title = mkxp_getGameTitle(), title[0] != 0 {
                    gameTitle = String(cString: title)
                    metadataLoaded = true
                }
            }
        }
    }

    private var fpsColor: Color {
        if fps >= 55 { return .success }
        if fps >= 30 { return .warning }
        return .destructive
    }
}

// MARK: - FPS Ring Buffer

private struct FPSRingBuffer {
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
