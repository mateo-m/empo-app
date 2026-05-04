import SwiftUI

struct ImportButton: View {
    var showEmpty: Bool
    @Binding var showImporter: Bool
    var splashDismissed: Bool
    var entranceDelay: TimeInterval
    var headerHeight: CGFloat
    var emptyStateHeight: CGFloat
    var emptyStateOffset: CGFloat
    /// True while one or more pre-flight validations are running.
    /// During this window the button swaps its "Import game" label
    /// for a "Validating" spinner and taps prompt a cancel
    /// confirmation instead of opening the picker.
    var isValidating: Bool = false
    var onRequestCancelValidation: (() -> Void)?

    @State private var importShimmer: CGFloat = -1
    @State private var importMoveTrigger = 0
    @State private var buttonHeight: CGFloat = AppSize.minTapTarget
    @State private var revealed = false

    var body: some View {
        GeometryReader { geo in
            let collapsed = !showEmpty
            let buttonSize: CGFloat = AppSize.toolbarButton

            // End positions (center coordinates)
            let collapsedX = geo.size.width - 16 - buttonSize / 2
            let collapsedY = headerHeight / 2
            let expandedX = geo.size.width / 2
            let emptyStateBottom = geo.size.height / 2 + emptyStateOffset + emptyStateHeight / 2
            let expandedY = emptyStateBottom + Spacing._4xl + buttonHeight / 2

            // Arc: find center of rotation on perpendicular bisector
            let chordDX = collapsedX - expandedX
            let chordDY = collapsedY - expandedY
            let curvature: CGFloat = -1.5  // larger = gentler/subtler arc
            let arcCenterX = (expandedX + collapsedX) / 2 + curvature * (-chordDY)
            let arcCenterY = (expandedY + collapsedY) / 2 + curvature * chordDX

            // Offset from arc center to expanded position
            let offX = expandedX - arcCenterX
            let offY = expandedY - arcCenterY

            // Arc sweep angle (expanded → collapsed)
            let startAngle = atan2(offY, offX)
            let endAngle = atan2(collapsedY - arcCenterY, collapsedX - arcCenterX)
            let arcDeg = (endAngle - startAngle) * 180 / .pi

            Button(action: {
                if isValidating {
                    onRequestCancelValidation?()
                } else {
                    showImporter = true
                }
            }) {
                importButtonLabel(collapsed: collapsed)
            }
            .buttonStyle(.plain)
            // Label text is either hidden ("+" only, collapsed state)
            // or localised to "Import game"; either way VoiceOver
            // needs a stable announcement that doesn't flip between
            // "Plus button" and "Import game button" during the
            // collapsed<->expanded morph.
            .accessibilityLabel(isValidating ? "Cancel import" : "Import game")
            .onChange(of: collapsed) { _, _ in
                Haptics.tap()
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                buttonHeight = $0
            }
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
            // Entrance reveal (before arc transforms so it's in local space)
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.8)
            .blur(radius: revealed ? 0 : 10)
            // Counter-rotate to keep content upright through the
            // sweep. The three modifiers below step the button
            // from the expanded anchor to the collapsed anchor
            // along an arc: offset to the expanded position
            // relative to the arc center, rotate by the sweep
            // angle, then place at the arc center.
            .rotationEffect(.degrees(collapsed ? -arcDeg : 0))
            .offset(x: offX, y: offY)
            .rotationEffect(.degrees(collapsed ? arcDeg : 0))
            .position(x: arcCenterX, y: arcCenterY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: showEmpty)
            .animation(Motion.standard, value: isValidating)
            .onChange(of: showEmpty) { importMoveTrigger += 1 }
            .onAppear {
                if splashDismissed {
                    revealed = true
                    withAnimation(.easeInOut(duration: 1.5).delay(0.4)) {
                        importShimmer = 2
                    }
                }
            }
            .onChange(of: splashDismissed) { _, dismissed in
                guard dismissed else { return }
                let revealDelay =
                    entranceDelay + EmptyStateView.staggerInterval * Double(EmptyStateView.elementCount)
                withAnimation(Motion.standard.delay(revealDelay)) {
                    revealed = true
                }
                withAnimation(.easeInOut(duration: 1.5).delay(revealDelay + 0.5)) {
                    importShimmer = 2
                }
            }
        }
    }

    @ViewBuilder
    private func importButtonLabel(collapsed: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            importButtonIcon
                .id(isValidating ? "validating" : "idle")
                .transition(.blurReplace)
            if !collapsed {
                Text(isValidating ? "Validating" : "Import game")
                    .contentTransition(.numericText())
                    .transition(.blurReplace)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(Alpha.shadow), radius: 2, y: 1)
        .padding(.horizontal, collapsed ? 0 : ButtonSize.lg.horizontalPadding)
        .padding(.vertical, collapsed ? 0 : ButtonSize.lg.verticalPadding)
        .frame(
            width: collapsed ? AppSize.toolbarButton : nil,
            height: collapsed ? AppSize.toolbarButton : nil
        )
        .glassEffect(.regular.tint(.brand).interactive(), in: .capsule)
        .darkGlass()
    }

    @ViewBuilder
    private var importButtonIcon: some View {
        if isValidating {
            SpinnerRing(progress: 0, size: 18, lineWidth: 2)
        } else {
            Image(systemName: "plus")
        }
    }
}

private struct ImportButtonSquash {
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
}
