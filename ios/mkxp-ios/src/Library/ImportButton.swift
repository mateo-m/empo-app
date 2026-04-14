import SwiftUI

struct ImportButton: View {
    var showEmpty: Bool
    @Binding var showImporter: Bool
    var splashDismissed: Bool
    var entranceDelay: TimeInterval
    var headerHeight: CGFloat

    @State private var importGlowing = false
    @State private var importRevealed = false
    @State private var importShimmer: CGFloat = -1
    @State private var importMoveTrigger = 0

    var body: some View {
        GeometryReader { geo in
            let collapsed = !showEmpty
            let buttonSize: CGFloat = AppSize.toolbarButton

            // End positions (center coordinates)
            let collapsedX = geo.size.width - 16 - buttonSize / 2
            let collapsedY = headerHeight / 2
            let expandedX = geo.size.width / 2
            let expandedY = geo.size.height / 2 + 110

            // Arc: find center of rotation on perpendicular bisector
            let chordDX = collapsedX - expandedX
            let chordDY = collapsedY - expandedY
            let curvature: CGFloat = -1.5 // larger = gentler/subtler arc
            let arcCenterX = (expandedX + collapsedX) / 2 + curvature * (-chordDY)
            let arcCenterY = (expandedY + collapsedY) / 2 + curvature * chordDX

            // Offset from arc center to expanded position
            let offX = expandedX - arcCenterX
            let offY = expandedY - arcCenterY

            // Arc sweep angle (expanded → collapsed)
            let startAngle = atan2(offY, offX)
            let endAngle = atan2(collapsedY - arcCenterY, collapsedX - arcCenterX)
            let arcDeg = (endAngle - startAngle) * 180 / .pi

            Button(action: { showImporter = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    if !collapsed {
                        Text("Import game")
                            .font(.body.weight(.semibold))
                            .transition(.blurReplace)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, collapsed ? 10 : 20)
                .padding(.vertical, collapsed ? 10 : 12)
            }
            .glassEffect(.regular.tint(.brand).interactive(), in: .capsule)
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.25), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: UnitPoint(x: importShimmer - 0.3, y: importShimmer - 0.3),
                            endPoint: UnitPoint(x: importShimmer, y: importShimmer)
                        )
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .brand.opacity(collapsed ? 0 : (importGlowing ? 0.5 : 0.15)),
                    radius: collapsed ? 0 : (importGlowing ? 16 : 6))
            .environment(\.colorScheme, .dark)
            // Scale-based reveal: glass effect initializes at near-zero scale
            // (fully tinted but invisible), avoiding the gray flash that
            // opacity-based reveals cause.
            .scaleEffect(importRevealed ? 1 : 0.001)
            .allowsHitTesting(importRevealed)
            .keyframeAnimator(
                initialValue: ImportButtonSquash(),
                trigger: importMoveTrigger
            ) { content, value in
                content.scaleEffect(x: value.scaleX, y: value.scaleY)
            } keyframes: { _ in
                KeyframeTrack(\.scaleX) {
                    SpringKeyframe(1.18, duration: 0.12, spring: .snappy)
                    SpringKeyframe(0.92, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
                KeyframeTrack(\.scaleY) {
                    SpringKeyframe(0.85, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.08, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
            }
            // Counter-rotate to keep content upright
            .rotationEffect(.degrees(collapsed ? -arcDeg : 0))
            // Offset from arc center to expanded position
            .offset(x: offX, y: offY)
            // Arc sweep rotation
            .rotationEffect(.degrees(collapsed ? arcDeg : 0))
            // Place at arc center
            .position(x: arcCenterX, y: arcCenterY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: showEmpty)
            .onChange(of: showEmpty) { importMoveTrigger += 1 }
            .onAppear {
                if splashDismissed {
                    importRevealed = true
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        importGlowing = true
                    }
                }
            }
            .onChange(of: splashDismissed) { _, dismissed in
                guard dismissed else { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.2).delay(entranceDelay + 0.1)) {
                    importRevealed = true
                }
            }
            .onChange(of: importRevealed) {
                guard importRevealed else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    importGlowing = true
                }
                withAnimation(.easeInOut(duration: 1.5).delay(0.4)) {
                    importShimmer = 2
                }
            }
        }
    }

}

// MARK: - Squash-and-Stretch Keyframe Values

private struct ImportButtonSquash {
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
}
