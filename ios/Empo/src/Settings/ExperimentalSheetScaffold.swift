import SwiftUI

/// Shared layout/presentation chrome for experimental-flow sheets
/// (the opt-in confirmation AND the "what does experimental mean"
/// info sheet). Consolidating here keeps the two sheets visually
/// identical: same background, same heavy corner radius, same padding
/// grid.
///
/// The palette intensifies the current scheme rather than inverting it:
/// dark mode gets a deeper-than-system-dark surface, light mode gets a
/// brighter-than-system-light surface. This creates clear figure/ground
/// separation without the jarring full inversion. Rounded corners are
/// exaggerated (48pt) so the sheet reads as a card, not a system surface.
/// Palette for the experimental sheets. Dark mode gets a deeper-than-
/// dark surface; light mode gets a brighter-than-light surface. This
/// keeps the sheet feeling like a distinct layer on top of Settings
/// without the jarring full-inversion of the previous white-on-dark
/// approach.
enum ExperimentalSheetPalette {
    static func background(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.16)   // slightly lifted from system dark
            : Color(white: 0.97)   // brighter than system light
    }

    static func foreground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.95)
            : Color(white: 0.10)
    }

    static func secondaryForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.60)
            : Color(white: 0.40)
    }
}

struct ExperimentalSheetScaffold<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredHeight: CGFloat = 0
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing._2xl) {
            content
        }
        .padding(.horizontal, Spacing._2xl)
        .padding(.top, Spacing._3xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Force the VStack to use its intrinsic height instead of
        // expanding to fill the proposed height. Without this, the
        // geometry reader below measures the *proposed* (full-screen)
        // height, causing the detent to overshoot.
        .fixedSize(horizontal: false, vertical: true)
        // Measure the content height so the sheet sizes itself to the
        // content. `.presentationSizing(.form)` expanded to fill on
        // iPhone; fixed detents left a huge empty lower half under
        // short content. `.presentationDetents([.height(x)])` with a
        // measured x is the reliable way to fit-to-content.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            measuredHeight = newHeight
        }
        .presentationDetents(
            measuredHeight > 0
                ? [.height(measuredHeight)]
                : [.medium]
        )
        .presentationBackground {
            ZStack {
                ExperimentalSheetPalette.background(for: colorScheme)
                // Thin luminance edge gives the sheet a defined boundary
                // against the dimmed content underneath, creating visual
                // lift without a drop shadow.
                RoundedRectangle(cornerRadius: 56)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.0),
                        lineWidth: 1
                    )
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(56)
    }
}
