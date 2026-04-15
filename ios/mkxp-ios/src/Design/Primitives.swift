import SwiftUI

// MARK: - Haptics

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    private static var interfaceEnabled: Bool {
        UserDefaults.standard.object(forKey: "interfaceHaptics") as? Bool ?? true
    }

    private static var controllerEnabled: Bool {
        UserDefaults.standard.object(forKey: "controllerHaptics") as? Bool ?? true
    }

    static func tap() {
        guard interfaceEnabled else { return }
        light.impactOccurred()
    }

    static func impact() {
        guard interfaceEnabled else { return }
        medium.impactOccurred()
    }

    static func success() {
        guard interfaceEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func controllerTap() {
        guard controllerEnabled else { return }
        light.impactOccurred()
    }
}

// MARK: - Button Styles

enum ButtonSize {
    case sm, md, lg

    var horizontalPadding: CGFloat {
        switch self {
        case .sm: Spacing.md
        case .md: Spacing.xl
        case .lg: Spacing._2xl
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .sm: Spacing.xs
        case .md: Spacing.md
        case .lg: Spacing.lg
        }
    }

    var font: Font {
        switch self {
        case .sm: .subheadline
        case .md: .body
        case .lg: .body
        }
    }
}

/// Brand-tinted glass with contrast text and pulsing glow — main CTAs.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, size: size, isEnabled: isEnabled)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: ButtonSize
    let isEnabled: Bool
    @State private var glowing = false

    var body: some View {
        configuration.label
            .font(size.font.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(.regular.tint(.brand).interactive(), in: .capsule)
            .environment(\.colorScheme, .dark)
            .shadow(color: .brand.opacity(glowing ? 0.5 : 0.15),
                    radius: glowing ? 16 : 6)
            .opacity(isEnabled ? 1 : 0.4)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    glowing = true
                }
            }
    }
}

/// Lightly brand-tinted glass with brand-colored text — supporting actions.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(.brand)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(.regular.tint(.brand.opacity(0.1)).interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// Glass with subtle border — low-emphasis actions.
struct OutlineButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.primary.opacity(0.7))
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(Capsule().strokeBorder(.quaternary.opacity(0.5), lineWidth: 1))
            .glassEffect(.regular.interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : 0.4)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(size: ButtonSize) -> PrimaryButtonStyle { PrimaryButtonStyle(size: size) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(size: ButtonSize) -> SecondaryButtonStyle { SecondaryButtonStyle(size: size) }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static func outline(size: ButtonSize) -> OutlineButtonStyle { OutlineButtonStyle(size: size) }
}

/// Scale-down press effect for tappable cards.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

// MARK: - Empty State

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
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .offset(y: floating ? -6 : 6)
                .animation(
                    .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                    value: floating
                )
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
            let spring = Animation.spring(duration: 0.3, bounce: 0)
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
            // Start floating after all elements reveal
            let totalDelay = initialDelay + interval * 2 + 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
                floating = true
            }
        }
    }
}

// MARK: - Staggered Appearance

struct StaggeredAppearance: ViewModifier {
    let index: Int
    let trigger: UUID
    var initialDelay: TimeInterval = 0

    private var delay: Double { initialDelay + Double(index) * 0.04 }

    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .onChange(of: trigger) {
                visible = false
                DispatchQueue.main.async {
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

// MARK: - Transitions

struct EmptyStateTransition: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 10 : 0)
    }
}

struct CardTransition: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

struct ViewModeSwitchTransition: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 10 : 0)
    }
}

extension AnyTransition {
    static var emptyState: AnyTransition {
        .modifier(
            active: EmptyStateTransition(active: true),
            identity: EmptyStateTransition(active: false)
        )
    }

    static var cardAppear: AnyTransition {
        .modifier(
            active: CardTransition(active: true),
            identity: CardTransition(active: false)
        )
    }

    static var viewModeSwitch: AnyTransition {
        .modifier(
            active: ViewModeSwitchTransition(active: true),
            identity: ViewModeSwitchTransition(active: false)
        )
    }
}
