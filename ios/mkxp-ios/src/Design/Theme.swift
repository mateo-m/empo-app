import SwiftUI

// MARK: - Colors
//
// 60-30-10 rule:
//   60% neutral  — system backgrounds, primary/secondary text (iOS defaults)
//   30% secondary — tinted surfaces, cards, badges, supporting elements
//   10% accent    — CTAs, toggles, active/highlighted states
//
// The accent color is brand orange. The secondary is a warm-tinted neutral
// derived from the accent — it creates cohesion without competing.

extension Color {
    static let brand = Color.orange

    /// Dark: warm dark surface with a hint of amber.
    /// Light: warm off-white with a hint of peach.
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1.0)
            : UIColor(red: 1.00, green: 0.97, blue: 0.93, alpha: 1.0)
    })
}

extension ShapeStyle where Self == Color {
    static var brand: Color { .brand }
    static var surface: Color { .surface }
    static var destructive: Color { .destructive }
    static var success: Color { .success }
    static var warning: Color { .warning }
}

// MARK: - Semantic Colors

extension Color {
    static let destructive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.38, blue: 0.35, alpha: 1.0)
            : UIColor(red: 0.90, green: 0.24, blue: 0.20, alpha: 1.0)
    })

    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.35, green: 0.90, blue: 0.50, alpha: 1.0)
            : UIColor(red: 0.20, green: 0.72, blue: 0.35, alpha: 1.0)
    })

    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.82, blue: 0.35, alpha: 1.0)
            : UIColor(red: 0.90, green: 0.70, blue: 0.10, alpha: 1.0)
    })
}

// MARK: - Spacing
//
// 4-point grid.

enum Spacing {
    /// 2pt — hairline gaps, tight label spacing
    static let xxs: CGFloat = 2
    /// 4pt — minimal padding, inline icon gaps
    static let xs: CGFloat = 4
    /// 6pt — compact element spacing
    static let sm: CGFloat = 6
    /// 8pt — standard inner padding, small gaps
    static let md: CGFloat = 8
    /// 12pt — grid gutter, between related elements
    static let lg: CGFloat = 12
    /// 16pt — section padding, screen-edge horizontal margins
    static let xl: CGFloat = 16
    /// 20pt — generous section spacing
    static let xxl: CGFloat = 20
    /// 32pt — large section breaks
    static let xxxl: CGFloat = 32
    /// 40pt — extra-large section breaks
    static let xxxxl: CGFloat = 40
}

// MARK: - Corner Radius

enum Radius {
    /// 4pt — small chips, inline badges
    static let xs: CGFloat = 4
    /// 8pt — thumbnails, list row artwork
    static let sm: CGFloat = 8
    /// 12pt — cards, dialogs, sheets
    static let md: CGFloat = 12
    /// 16pt — large cards, prominent containers
    static let lg: CGFloat = 16
    /// 24pt — hero elements, large artwork
    static let xl: CGFloat = 24
}

// MARK: - Shadows

extension View {
    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    func textShadow() -> some View {
        shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
    }

    func iconShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
    }

    func elevatedShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }
}

// MARK: - Animation
//
// Named spring presets — all tuned for a playful, fluid feel.

enum Motion {
    // -- Small elements: buttons, toggles, icons (150-200ms) --

    /// Quick micro-interaction — button press, toggle, small state change.
    static let snappy = Animation.spring(duration: 0.18, bounce: 0.0)

    // -- Big elements: cards, rows, navigation, layout shifts (250-350ms) --

    /// General-purpose transition — list changes, layout shifts, navigation.
    static let standard = Animation.spring(duration: 0.3, bounce: 0.0)

    /// Playful, expressive motion — import button arc, select accents.
    /// One of the few animations with bounce.
    static let bouncy = Animation.spring(duration: 0.35, bounce: 0.15)

    /// Gentle transition — background changes, slow reveals.
    static let gentle = Animation.spring(duration: 0.35, bounce: 0.0)

    // MARK: - Durations (for non-spring animations)

    /// Fast — opacity fades, color changes (small elements).
    static let durationFast: TimeInterval = 0.18
    /// Normal — standard transitions (big elements).
    static let durationNormal: TimeInterval = 0.3
    /// Slow — emphasis transitions, loading reveals.
    static let durationSlow: TimeInterval = 0.5
}

// MARK: - Sizes

enum AppSize {
    static let toolbarButton: CGFloat = 38
    static let listArtwork: CGFloat = 48
    static let infoArtwork: CGFloat = 80
}

// MARK: - Overlay Opacity

enum Overlay {
    static let light: Double = 0.3
    static let medium: Double = 0.5
    static let heavy: Double = 0.6
}
