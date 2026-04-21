import SwiftUI

//
// 60-30-10 rule:
//   60% neutral  — system backgrounds, primary/secondary text (iOS defaults)
//   30% secondary — tinted surfaces, cards, badges, supporting elements
//   10% accent    — CTAs, toggles, active/highlighted states
//
// The accent color is brand orange. The secondary is a warm-tinted neutral
// derived from the accent — it creates cohesion without competing.

extension Color {
    // Pinned brand orange as a fixed RGB - not Color.orange. SwiftUI's
    // semantic Color.orange shifts toward yellow when rendered on
    // white backgrounds (like our inverted sheets), and the shift is
    // inconsistent enough across contexts that the brand looked
    // different from screen to screen. Fixed RGB gives us one
    // predictable orange everywhere.
    static let brand = Color(red: 0.98, green: 0.56, blue: 0.16)

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
    static let _2xl: CGFloat = 20
    /// 32pt — large section breaks
    static let _3xl: CGFloat = 32
    /// 40pt — extra-large section breaks
    static let _4xl: CGFloat = 40
}


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
    /// 56pt — modal sheets, experimental cards
    static let sheet: CGFloat = 56
}


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

    /// Drop shadow used on hero title text overlaid on game artwork,
    /// both on the splash and inside game-loading screens.
    func heroTitleShadow() -> some View {
        shadow(radius: 4)
    }

    /// Pin the Liquid Glass material to its dark variant. Used on
    /// player controls (toolbar, D-pad, action buttons, debug
    /// overlay) so the glass tone stays consistent regardless of
    /// system color scheme or backdrop brightness.
    func darkGlass() -> some View {
        environment(\.colorScheme, .dark)
    }
}


/// Typography tokens used for one-off sites that don't fit a
/// SwiftUI semantic text style. Prefer a semantic font
/// (`.body`, `.headline`) first; reach for these only when the
/// design needs a specific tuned size/weight/design.
enum AppFont {
    /// The Empo wordmark - splash and settings header.
    static let wordmark = Font.system(size: 40, weight: .bold, design: .rounded)

    /// A small bold button label (used by inline CTAs and chips).
    static let buttonSmall = Font.footnote.weight(.semibold)

    /// Fixed-width monospaced body for the debug overlay.
    static let debugBody = Font.footnote.monospaced()

    /// Bold monospaced title for the debug overlay.
    static let debugTitle = Font.body.bold().monospaced()
}

//
// Named spring presets.

enum Motion {
    // -- Small elements: buttons, toggles, icons (150-200ms) --

    /// Quick micro-interaction - button press, toggle, small state change.
    static let snappy = Animation.spring(duration: 0.18, bounce: 0.0)

    // -- Big elements: cards, rows, navigation, layout shifts (250-350ms) --

    /// General-purpose transition - list changes, layout shifts, navigation.
    static let standard = Animation.spring(duration: 0.3, bounce: 0.0)

    /// Gentle transition - background changes, slow reveals.
    static let gentle = Animation.spring(duration: 0.35, bounce: 0.0)

    /// Slow emphasis - loading reveals, large layout shifts.
    static let slow = Animation.spring(duration: 0.5, bounce: 0.0)

    // -- Specialized presets --

    /// Interactive press response - action buttons, D-pad. Paired with
    /// `PressScale.standard`.
    static let controlPress = Animation.spring(response: 0.2, dampingFraction: 0.7)

    /// Near-instant state change - per-arm highlight on / off in the
    /// D-pad, slider thumb snap, etc.
    static let instant = Animation.easeOut(duration: 0.08)

    /// Soft bouncy - import button arc, tip banner entrance.
    static let bouncy = Animation.spring(duration: 0.25, bounce: 0.15)

    /// Emphasized transition - loading handoffs, reveal beats.
    static let emphasize = Animation.spring(duration: 0.8, bounce: 0)

    /// Ambient float used on splash artwork and similar long-running
    /// decorative loops. Always `.repeatForever(autoreverses: true)`.
    static let float = Animation.easeInOut(duration: 2.4)
        .repeatForever(autoreverses: true)

    /// Spinner rotation - linear and looping.
    static let spinner = Animation.linear(duration: 1)
        .repeatForever(autoreverses: false)

    // -- Stagger --

    /// Interval between successive items in a cascading entrance
    /// (library grid, settings list). Slightly longer than
    /// `staggerFast` so a row of 6-8 items reads as a wave.
    static let staggerInterval: TimeInterval = 0.04

    /// Faster stagger used in denser/wider lists where the sum of
    /// delays would otherwise feel sluggish.
    static let staggerFast: TimeInterval = 0.04

    // -- Durations (for manual withAnimation(.easeInOut(duration:))) --

    /// Fast - opacity fades, color changes (small elements).
    static let durationFast: TimeInterval = 0.18
    /// Normal - standard transitions (big elements).
    static let durationNormal: TimeInterval = 0.3
    /// Gentle - background changes, slow reveals.
    static let durationGentle: TimeInterval = 0.35
    /// Slow - emphasis transitions, loading reveals.
    static let durationSlow: TimeInterval = 0.5
}


/// Press-scale values used when a button-like surface reacts to
/// touch. Kept as one canonical number so action buttons, cards, and
/// the D-pad press identically.
enum PressScale {
    /// The standard press-down scale.
    static let standard: CGFloat = 0.95
}


enum AppSize {
    static let toolbarButton: CGFloat = 38
    static let listArtwork: CGFloat = 48
    static let infoArtwork: CGFloat = 80
    static let debugOverlayWidth: CGFloat = 220
    /// Fallback height used only until the overlay has reported its
    /// actual rendered size via `DebugOverlayHeightKey`. Long titles or
    /// wrapped lines make the real height grow beyond this.
    static let debugOverlayInitialHeight: CGFloat = 140

    /// Library/settings navigation header tap area.
    static let libraryHeader: CGFloat = 56

    /// Slider value-label pinned width (right-aligned, so values like
    /// "100%" don't visually jump as the label width fluctuates).
    static let sliderValueLabel: CGFloat = 48
}


/// SF Symbol and small-icon sizing. Use instead of inline
/// `.font(.system(size: N))` on `Image(systemName:)` so icons stay
/// consistent across the app.
enum IconSize {
    /// Inline icon in a settings row, list row, or chip.
    static let row: CGFloat = 24
    /// Placeholder icon inside an empty slot (e.g. missing artwork).
    static let placeholder: CGFloat = 36
    /// Hero icon inside an empty-state illustration.
    static let emptyState: CGFloat = 48
}


/// Layered opacity tokens. Semantics:
///
/// - `Scrim.*` dims what's behind (typically black over the game
///   or a card).
/// - `Alpha.*` is for foreground content opacity (text, icons, rim
///   strokes, hairline dividers).
enum Scrim {
    /// Soft scrim - subtle veil (e.g. bottom-of-hero gradient).
    static let light: Double = 0.3
    /// Medium scrim - typical modal dim.
    static let medium: Double = 0.5
    /// Heavy scrim - full darken (e.g. disclaimer backdrop).
    static let heavy: Double = 0.6
}


enum Alpha {
    /// Muted foreground - secondary text/icons over images.
    static let textMuted: Double = 0.7
    /// High-opacity foreground - primary labels over images.
    static let textHighMuted: Double = 0.9
    /// Subtle rim or hairline divider.
    static let border: Double = 0.2
    /// Brand tint behind `.secondary` surfaces.
    static let brandTintBackground: Double = 0.1
}


/// Backwards-compat shim so incremental site-by-site migration is
/// safe: existing `Overlay.light/medium/heavy` call sites keep
/// working while we migrate to the split `Scrim` / `Alpha` tokens.
enum Overlay {
    static let light: Double = Scrim.light
    static let medium: Double = Scrim.medium
    static let heavy: Double = Scrim.heavy
}
