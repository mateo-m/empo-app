import SwiftUI

// ============================================================================
// MARK: - Button Styles
// ============================================================================

/// Scale-down press effect for tappable cards and large touch targets.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
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

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
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
            .scaleEffect(active ? 0.97 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
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
}
