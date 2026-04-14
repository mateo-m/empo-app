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

/// Brand-tinted glass with contrast text — main CTAs.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(.regular.tint(.brand).interactive(), in: .capsule)
            .environment(\.colorScheme, .dark)
            .shadow(color: .brand.opacity(0.15), radius: 6)
            .opacity(isEnabled ? 1 : 0.4)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
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
    @State private var floating = false
    @State private var appeared = false

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
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .accessibilityElement(children: .combine)
        .onChange(of: revealed, initial: true) {
            guard revealed, !appeared else { return }
            withAnimation(.spring(duration: 0.3, bounce: 0).delay(initialDelay)) {
                appeared = true
            }
            // Start floating after reveal finishes so the repeating animation
            // triggers while the icon is visible (not while opacity is 0).
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay + 0.3) {
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
