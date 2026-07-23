import SwiftUI

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

/// A solid glass capsule with the brand fill and white text. Use it for primary actions.
/// Pair it with `.secondary` for the supporting action.
struct PrimaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    var tint: Color = .brand
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : Alpha.disabled)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(size: ButtonSize) -> PrimaryButtonStyle { PrimaryButtonStyle(size: size) }
    static func primary(size: ButtonSize = .lg, tint: Color) -> PrimaryButtonStyle {
        PrimaryButtonStyle(size: size, tint: tint)
    }
}

/// Glass with a light brand tint and brand-colored text. Use it for supporting actions.
struct SecondaryButtonStyle: ButtonStyle {
    var size: ButtonSize = .lg
    var tint: Color = .brand
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font.weight(.medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(tint)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassEffect(.regular.tint(tint.opacity(Alpha.brandTintBackground)).interactive(), in: .capsule)
            .opacity(isEnabled ? 1 : Alpha.disabled)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(size: ButtonSize) -> SecondaryButtonStyle { SecondaryButtonStyle(size: size) }
    static func secondary(size: ButtonSize = .lg, tint: Color) -> SecondaryButtonStyle {
        SecondaryButtonStyle(size: size, tint: tint)
    }
}

/// A scale-down press effect for tappable cards.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? PressScale.standard : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.tap() }
            }
    }
}

/// A light opacity press effect for list rows.
struct ListRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? Alpha.textMuted : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
