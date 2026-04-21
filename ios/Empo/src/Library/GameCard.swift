import SwiftUI

struct GameCard: View {
    let game: GameEntry
    var isPaused: Bool = false
    var onStopImport: (() -> Void)? = nil
    @State private var titleHeight: CGFloat = 40

    private var titlePosition: TitlePosition { AppSettings.shared.titlePosition }

    var body: some View {
        switch titlePosition {
        case .inside: insideCard
        case .under:  underCard
        }
    }


    private var insideCard: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artworkView }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white.opacity(0.6), location: 0.5),
                                .init(color: .clear, location: 1.0),
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: titleHeight * 2.5)
                    .allowsHitTesting(false)
                    // Force dark scheme on the material so its tint
                    // stays dark — ensures the white title stays
                    // readable against every artwork.  Scoped here so
                    // the artwork placeholder underneath keeps its
                    // actual-scheme color.
                    .darkGlass()
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .textShadow()
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)

                    if let originalTitle = game.originalTitle {
                        Text(originalTitle)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .textShadow()
                            .lineLimit(1)
                    }
                }
                .padding(Spacing.md)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    titleHeight = newHeight
                }
            }
            .overlay { centerOverlay }
            .clipShape(.rect(cornerRadius: Radius.md))
            .cardShadow()
    }


    private var underCard: some View {
        VStack(spacing: Spacing.sm) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { artworkView }
                .overlay { centerOverlay }
                .clipShape(.rect(cornerRadius: Radius.md))
                .cardShadow()

            VStack(spacing: Spacing.xxs) {
                Text(game.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let originalTitle = game.originalTitle {
                    Text(originalTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }


    @ViewBuilder
    private var centerOverlay: some View {
        // Dim the artwork a little for non-ready states so the
        // indicator reads clearly against busy thumbnails.
        if game.status.phase != .ready {
            Color.black.opacity(Overlay.light)
        }
        GameStatusIndicator(
            kind: .resolve(status: game.status, paused: isPaused),
            onStopImport: onStopImport,
            size: 36
        )
    }

    @ViewBuilder
    private var artworkView: some View {
        GameArtworkView(
            artworkPath: game.artworkPath,
            importing: game.status.phase == .importing
        )
    }
}


struct GameListRow: View {
    let game: GameEntry
    var isPaused: Bool = false
    var heroNamespace: Namespace.ID? = nil
    var onStopImport: (() -> Void)? = nil

    // Without a stable namespace, SwiftUI creates separate structural
    // branches and destroys/recreates GameArtworkView on status change,
    // losing @State (breaks the saturation animation).
    @Namespace private var fallbackNamespace

    var body: some View {
        HStack(spacing: Spacing.lg) {
            // Artwork thumbnail. The transition source id is suffixed
            // with `-item` so this row doesn't conflict with the
            // "Continue playing" hero card above the list, which
            // registers the same game id under a different suffix.
            GameArtworkView(
                artworkPath: game.artworkPath,
                placeholderIconSize: 16,
                size: AppSize.listArtwork,
                cornerRadius: Radius.sm,
                importing: game.status.phase == .importing
            )
            .matchedTransitionSource(id: "\(game.id)-item", in: heroNamespace ?? fallbackNamespace) { config in
                config
                    .background(.black)
                    .clipShape(.rect(cornerRadius: Radius.sm))
            }

            // Title and original name
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(game.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let originalTitle = game.originalTitle {
                    Text(originalTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            GameStatusIndicator(
                kind: .resolve(status: game.status, paused: isPaused),
                onStopImport: onStopImport
            )
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}


/// Unified status badge used by both the grid card centerOverlay and the
/// list row trailing edge. Renders the circular glass background,
/// determinate/indeterminate progress ring (for imports), and the inner
/// icon (stop / play / pause / warning) as a coherent animated unit.
///
/// Takes a single `GameStatusIndicator.Kind` so the four mutually
/// exclusive display states are exhaustive at the type level. Callers
/// at the grid/list sites compute `.kind` from
/// `game.status` + `PauseManager.pausedGame` - mixing those two
/// concerns into the enum here would muddle `GameStatus` which only
/// knows about filesystem/import state, not about whether a session is
/// currently paused.
struct GameStatusIndicator: View {
    /// Exhaustive set of visual states. Paused is its own case
    /// (rather than a boolean on top of ready) so the `switch` in
    /// `innerIcon` and `indicatorBody` covers every branch without
    /// conditional flags.
    enum Kind: Hashable {
        case importing(progress: Double)
        case ready
        case paused
        case invalid
    }

    let kind: Kind
    var onStopImport: (() -> Void)? = nil
    /// Overall diameter. All inner metrics (ring, icon, stop square)
    /// scale from this single value so the list (34pt) and card (56pt)
    /// sites both look proportional.
    var size: CGFloat = AppSize.toolbarButton

    @Environment(\.colorScheme) private var colorScheme

    private var ringSize: CGFloat    { size * 0.82 }
    private var lineWidth: CGFloat   { size * 0.079 }
    private var stopSize: CGFloat    { size * 0.28 }
    private var iconFont: Font {
        size >= 44 ? .title3 : .caption
    }

    private var progress: Double {
        if case .importing(let p) = kind { return p }
        return 0
    }

    /// Paused state gets an inverted scheme for emphasis: a light badge
    /// in dark mode and a dark badge in light mode. Makes it pop
    /// against the surrounding glass/artwork without screaming for
    /// attention, which wouldn't be right for a passive "paused" state.
    private var pausedForeground: Color {
        colorScheme == .dark ? .black : .white
    }
    private var pausedBackgroundTint: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        // Shared glass chrome across ready / paused / invalid states.
        // Importing hides it because the SpinnerRing already provides
        // its own ring-as-container; stacking two rims looks muddled.
        // Uses the same `.glassEffect(.regular, in: .circle)` styling
        // as IconButton so the indicator reads as a sibling to toolbar
        // icons rather than a bespoke material blob.
        indicatorBody
            .frame(width: size, height: size)
            .animation(Motion.gentle, value: kind)
    }

    @ViewBuilder
    private var indicatorBody: some View {
        let core = ZStack {
            SpinnerRing(
                progress: progress,
                size: ringSize,
                lineWidth: lineWidth,
                tint: .primary,
                trackOpacity: 0.2
            )
            .opacity({ if case .importing = kind { true } else { false } }() ? 1 : 0)
            .scaleEffect({ if case .importing = kind { true } else { false } }() ? 1 : 0.5)

            // Inner icon — morphs between stop / play / pause / warning
            innerIcon
                .transition(.blurReplace)
        }

        switch kind {
        case .importing:
            core
        case .paused:
            // Inverted scheme tint so the paused badge reads stronger
            // than the ambient ready state.
            core.glassEffect(.regular.tint(pausedBackgroundTint), in: .circle)
        case .ready, .invalid:
            core.glassEffect(.regular, in: .circle)
        }
    }

    @ViewBuilder
    private var innerIcon: some View {
        switch kind {
        case .importing:
            Button(action: { onStopImport?() }) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.primary)
                    .frame(width: stopSize, height: stopSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop import")
        case .ready:
            Image(systemName: "play.fill")
                .font(iconFont)
                .foregroundStyle(.primary)
        case .paused:
            Image(systemName: "pause.fill")
                .font(iconFont)
                .foregroundStyle(pausedForeground)
        case .invalid:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(iconFont)
                .foregroundStyle(.warning)
        }
    }
}

extension GameStatusIndicator.Kind {
    /// Helper for the common call shape: feed the file-system status
    /// and the session-paused flag, get the right visual kind.
    /// Keeps the "paused only makes sense on ready" rule in one place.
    static func resolve(status: GameStatus, paused: Bool) -> Self {
        switch status {
        case .importing(let progress): .importing(progress: progress)
        case .invalid: .invalid
        case .ready: paused ? .paused : .ready
        }
    }
}
