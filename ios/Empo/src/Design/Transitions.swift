import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    var revealed: Bool = true
    var initialDelay: TimeInterval = 0.2
    static let staggerInterval: TimeInterval = 0.1
    static let elementCount = 3

    @State private var iconAppeared = false
    @State private var titleAppeared = false
    @State private var subtitleAppeared = false
    @State private var floating = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: IconSize.emptyState))
                .foregroundStyle(.secondary)
                .offset(y: floating ? -3 : 3)
                .animation(Motion.float, value: floating)
                .opacity(iconAppeared ? 1 : 0)
                .offset(y: iconAppeared ? 0 : 12)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .opacity(titleAppeared ? 1 : 0)
                .offset(y: titleAppeared ? 0 : 12)
            Text(subtitle)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .opacity(subtitleAppeared ? 1 : 0)
                .offset(y: subtitleAppeared ? 0 : 12)
        }
        .accessibilityElement(children: .combine)
        .onChange(of: revealed, initial: true) {
            guard revealed, !iconAppeared else { return }
            let spring = Motion.standard
            let interval = Self.staggerInterval
            withAnimation(spring.delay(initialDelay)) {
                iconAppeared = true
            }
            withAnimation(spring.delay(initialDelay + interval)) {
                titleAppeared = true
            }
            withAnimation(spring.delay(initialDelay + interval * 2)) {
                subtitleAppeared = true
            }
            let totalDelay = initialDelay + interval * 2 + 0.3
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(totalDelay))
                floating = true
            }
        }
    }
}

struct StaggeredAppearance: ViewModifier {
    let index: Int
    let trigger: UUID
    var initialDelay: TimeInterval = 0

    private var delay: Double { initialDelay + Double(index) * Motion.staggerFast }

    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .onChange(of: trigger) {
                visible = false
                Task { @MainActor in
                    withAnimation(Motion.standard.delay(delay)) {
                        visible = true
                    }
                }
            }
    }
}

extension View {
    func staggered(index: Int, trigger: UUID, initialDelay: TimeInterval = 0) -> some View {
        modifier(StaggeredAppearance(index: index, trigger: trigger, initialDelay: initialDelay))
    }
}

struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

struct ScaleFadeBlurTransition: ViewModifier {
    let active: Bool
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? blurRadius : 0)
    }
}

struct ControlTransition: ViewModifier {
    let active: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1, anchor: anchor)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    static var emptyState: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 10),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 10)
        )
    }

    static var cardAppear: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 6),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 6)
        )
    }

    static var viewModeSwitch: AnyTransition {
        .modifier(
            active: ScaleFadeBlurTransition(active: true, blurRadius: 10),
            identity: ScaleFadeBlurTransition(active: false, blurRadius: 10)
        )
    }

    static func controlAppear(anchor: UnitPoint) -> AnyTransition {
        .modifier(
            active: ControlTransition(active: true, anchor: anchor),
            identity: ControlTransition(active: false, anchor: anchor)
        )
    }

    static var hintBanner: AnyTransition {
        let blurIn = AnyTransition.modifier(
            active: BlurModifier(radius: 8),
            identity: BlurModifier(radius: 0)
        )
        return .opacity.combined(with: .move(edge: .top)).combined(with: blurIn)
    }
}
