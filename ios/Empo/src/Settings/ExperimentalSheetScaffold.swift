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
/// separation without jarring full inversion. Rounded corners are
/// exaggerated (48pt) so the sheet reads as a card, not a system surface.
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

    /// Shown centered at the top of the sheet in the native inline
    /// nav-bar title style (`.headline` weight/size). Required because
    /// every sheet that uses this scaffold has a title and we want them
    /// to look and feel consistent with the rest of the app's sheets.
    let title: String

    /// Optional small chip-like label rendered directly below the
    /// title, e.g. an "Experimental" tag with a flask icon. Positioned
    /// as a subtitle annotation rather than a pre-title overline so
    /// the title always comes first in the visual hierarchy.
    let caption: Caption?

    /// Optional short descriptive paragraph rendered under the title
    /// block, styled to match iOS alert/action-sheet message text
    /// (`.subheadline`, regular weight, secondary color, centered).
    /// Sheets with richer multi-paragraph or bullet content should
    /// leave this nil and render that content in `content` instead.
    let message: String?

    let content: Content

    struct Caption {
        let text: String
        let systemImage: String?

        init(_ text: String, systemImage: String? = nil) {
            self.text = text
            self.systemImage = systemImage
        }
    }

    init(
        title: String,
        caption: Caption? = nil,
        message: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.message = message
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing._2xl) {
            // Header: title, optional caption beneath it, optional
            // description message. The title matches iOS native inline
            // nav bar titles (.headline, centered) and the description
            // matches alert/action-sheet message text (.subheadline,
            // regular, secondary) so this scaffold sits alongside the
            // rest of the app's sheets without feeling bespoke.
            VStack(spacing: Spacing.sm) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(ExperimentalSheetPalette.foreground(for: colorScheme))
                    .multilineTextAlignment(.center)

                if let caption {
                    HStack(spacing: Spacing.xs) {
                        if let systemImage = caption.systemImage {
                            Image(systemName: systemImage)
                        }
                        Text(caption.text)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.brand)
                }

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ExperimentalSheetPalette.secondaryForeground(for: colorScheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity)

            content
        }
        .padding(.horizontal, Spacing._2xl)
        .padding(.top, Spacing._2xl)
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
                RoundedRectangle(cornerRadius: Radius.sheet)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.0),
                        lineWidth: 1
                    )
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
        // Tapping the dimmed backdrop must NOT dismiss; the user has
        // to use one of the sheet's own buttons. This also blocks the
        // drag-to-dismiss gesture.
        .interactiveDismissDisabled(true)
    }
}
