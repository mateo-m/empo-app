// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// The measured height of the overlay. Long titles and wrapped lines
/// make the overlay taller than the first guess.
struct DebugOverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The player view keeps this state while the overlay is hidden, so the
/// graphs and the game title stay.
@MainActor @Observable
final class DebugOverlayState {
    var fps: Double = 0
    /// The frame rate that the game asks for (`Graphics.frame_rate`).
    /// RPG Maker XP games usually ask for 40, VX and VX Ace games for 60,
    /// and Pokemon Essentials games for a value between. 0 until the
    /// engine sends a value.
    var targetFPS: Double = 0
    var gameTitle: String = "--"
    var details: [String] = []
    var ringBuffer = FPSRingBuffer(capacity: 120)
    var metadataLoaded = false
    /// `phys_footprint`, the value of the Xcode memory gauge. 0 when the
    /// query fails.
    var memoryMB: Double = 0
    var memoryBuffer = FPSRingBuffer(capacity: 120)
    var runner: GameRunner = .app
    /// For the runner `.gameProcess`. `memoryMB` is then the footprint
    /// of the app only.
    var processMemoryMB: Double = 0
    var processMemoryBuffer = FPSRingBuffer(capacity: 120)

    var isGameReady: Bool { gamecore_isGameReady() != 0 }

    func sample() {
        guard gamecore_isEngineTerminated() == 0 else { return }
        fps = gamecore_getAverageFPS()
        targetFPS = Double(gamecore_getTargetFPS())
        ringBuffer.append(fps)
        runner = EngineSessionCoordinator.shared.runner
        memoryMB = Self.currentMemoryMB()
        if memoryMB > 0 {
            memoryBuffer.append(memoryMB)
        }
        if runner == .gameProcess {
            processMemoryMB = Double(EmpoGameProcessClient.memoryFootprint()) / 1_048_576.0
            if processMemoryMB > 0 {
                processMemoryBuffer.append(processMemoryMB)
            }
        }

        // The core adds some lines only after the renderer starts.
        let details = String(cString: gamecore_getDetails())
            .split(separator: "\n").map(String.init)
        if details != self.details { self.details = details }

        if !metadataLoaded {
            if let title = gamecore_getGameTitle(), title[0] != 0 {
                gameTitle = String(cString: title)
                metadataLoaded = true
            }
        }
    }

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
}

struct DebugOverlayView: View {
    let state: DebugOverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            debugText(state.gameTitle, font: AppFont.debugTitle, color: .white)

            ForEach(state.details, id: \.self) { line in
                debugText(line)
            }

            debugText(
                state.isGameReady ? "Running" : "Loading\u{2026}",
                color: state.isGameReady ? .success : .warning
            )

            debugText(state.runner == .gameProcess ? "Runs in a game process" : "Runs in the app")

            if state.runner == .gameProcess {
                memoryRow("Game", megabytes: state.processMemoryMB, samples: state.processMemoryBuffer)
                memoryRow("App", megabytes: state.memoryMB, samples: state.memoryBuffer)
            } else {
                memoryRow("Memory", megabytes: state.memoryMB, samples: state.memoryBuffer)
            }

            HStack(spacing: Spacing.xs) {
                Text(verbatim: "\(Int(state.fps.rounded())) FPS")
                    .font(AppFont.debugFPS)
                    .monospacedDigit()
                    .foregroundStyle(fpsColor)
                    .frame(width: 104, alignment: .leading)

                // A Canvas has no size of its own. With no fixed height,
                // it takes all the height that it gets.
                Canvas { context, size in
                    // A trace on this line runs at the frame cap of the game.
                    let capY = size.height - (frameCap / graphMaxFPS) * size.height
                    var capLine = Path()
                    capLine.move(to: CGPoint(x: 0, y: capY))
                    capLine.addLine(to: CGPoint(x: size.width, y: capY))
                    context.stroke(
                        capLine,
                        with: .color(.white.opacity(Alpha.indicatorStroke)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )

                    guard let path = Self.graphPath(state.ringBuffer, in: size, low: 0, range: graphMaxFPS)
                    else { return }
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
            state.sample()
        }
    }

    /// The graph scales from the lowest to the highest sample, so a small
    /// growth stays visible on a high base.
    @ViewBuilder
    private func memoryRow(_ label: String, megabytes: Double, samples buffer: FPSRingBuffer) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(megabytes > 0 ? String(format: "%@ %.0f MB", label, megabytes) : "\(label) --")
                .font(AppFont.debugBody)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(Alpha.textMuted))
                .frame(width: 104, alignment: .leading)

            Canvas { context, size in
                let samples = buffer.samples
                let low = samples.min() ?? 0
                // A flat line has a range of 0. The minimum range of 1
                // keeps the line in the canvas.
                let range = max((samples.max() ?? 0) - low, 1)
                guard let path = Self.graphPath(buffer, in: size, low: low, range: range) else { return }
                context.stroke(path, with: .color(.white.opacity(Alpha.textMuted)), lineWidth: 1.5)
            }
            .frame(height: 28)
        }
    }

    /// Nil with fewer than 2 samples.
    private static func graphPath(
        _ buffer: FPSRingBuffer, in size: CGSize, low: Double, range: Double
    ) -> Path? {
        let samples = buffer.samples
        guard samples.count >= 2 else { return nil }
        var path = Path()
        for (i, sample) in samples.enumerated() {
            let point = CGPoint(
                x: CGFloat(i) / CGFloat(buffer.capacity - 1) * size.width,
                y: max(0, min(size.height, size.height - ((sample - low) / range) * size.height)))
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    /// 60, the RGSS2 and RGSS3 default, until the engine sends the cap.
    private var frameCap: Double {
        state.targetFPS > 0 ? state.targetFPS : 60
    }

    /// The space above the cap keeps the trace off the top edge.
    private var graphMaxFPS: Double {
        frameCap * 1.2
    }

    /// The thresholds are fractions of the frame cap of the game.
    private var fpsColor: Color {
        let ratio = state.fps / frameCap
        if ratio >= 0.9 { return .success }
        if ratio >= 0.5 { return .warning }
        return .destructive
    }

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

    /// The oldest sample first.
    var samples: [Double] {
        if count < capacity {
            return Array(buffer[0..<count])
        }
        return Array(buffer[writeIndex..<capacity]) + Array(buffer[0..<writeIndex])
    }
}
