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
