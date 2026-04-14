import SwiftUI

// ============================================================================
// MARK: - Haptics
// ============================================================================

/// Lightweight haptic feedback helpers.
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    /// Light tap — card press, small interactions.
    static func tap() {
        guard AppSettings.shared.interfaceHaptics else { return }
        light.impactOccurred()
    }

    /// Medium impact — import complete, significant action.
    static func impact() {
        guard AppSettings.shared.interfaceHaptics else { return }
        medium.impactOccurred()
    }

    /// Success — game launched successfully.
    static func success() {
        guard AppSettings.shared.interfaceHaptics else { return }
        notification.notificationOccurred(.success)
    }

    /// Light tap for game controller buttons.
    static func controllerTap() {
        guard AppSettings.shared.controllerHaptics else { return }
        light.impactOccurred()
    }
}

// ============================================================================
// MARK: - Button Styles
// ============================================================================

/// Scale-down press effect for tappable cards and large touch targets.
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

// ============================================================================
// MARK: - Empty State
// ============================================================================

/// A centered empty-state placeholder with icon, title, and subtitle.
/// Used when a collection has no content (library, search results, etc.).
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

// ============================================================================
// MARK: - Staggered Appearance
// ============================================================================

/// Fades and slides in a view with a staggered delay based on its index.
/// Resets and replays whenever `trigger` changes (e.g. on view mode switch).
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
    /// Staggered entrance animation — replays whenever `trigger` changes.
    func staggered(index: Int, trigger: UUID, initialDelay: TimeInterval = 0) -> some View {
        modifier(StaggeredAppearance(index: index, trigger: trigger, initialDelay: initialDelay))
    }
}

// ============================================================================
// MARK: - Transitions
// ============================================================================

/// Scale + blur + fade for empty state appearance/disappearance.
struct EmptyStateTransition: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 10 : 0)
    }
}

/// Subtle scale + blur + fade for card/row insertion/removal.
struct CardTransition: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

/// Scale + blur + fade for view mode switching (grid ↔ list).
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
