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
            // Force dark scheme so the material overlay stays dark-tinted —
            // ensures white text is readable even on the light-mode placeholder.
            .environment(\.colorScheme, .dark)
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
        switch game.status {
        case .importing:
            Color.black.opacity(Overlay.light)
            ImportProgressView(progress: game.importProgress, onStop: onStopImport)
        case .invalid:
            Color.black.opacity(Overlay.light)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.warning)
                .iconShadow()
        case .ready:
            if isPaused {
                // Paused indicator
                Color.black.opacity(Overlay.light + 0.05)
                Image(systemName: "pause.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .iconShadow()
            } else {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .iconShadow()
                    .background(
                        Circle()
                            .fill(.thinMaterial)
                            .mask(
                                RadialGradient(
                                    colors: [.white, .white.opacity(0.5), .white.opacity(0.15), .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 30
                                )
                            )
                            .frame(width: 60, height: 60)
                    )
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        GameArtworkView(
            artworkPath: game.artworkPath,
            importing: game.status.phase == .importing
        )
    }
}


private struct ImportProgressView: View {
    let progress: Double
    var size: CGFloat = 36
    var tint: Color = .white
    var onStop: (() -> Void)? = nil

    private var stopSize: CGFloat { size * 0.333 }

    var body: some View {
        ZStack {
            SpinnerRing(progress: progress, size: size, tint: tint)

            Button(action: { onStop?() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: stopSize, height: stopSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop import")
        }
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
            // Artwork thumbnail
            GameArtworkView(
                artworkPath: game.artworkPath,
                placeholderIconSize: 16,
                size: AppSize.listArtwork,
                cornerRadius: Radius.sm,
                importing: game.status.phase == .importing
            )
            .matchedTransitionSource(id: game.id, in: heroNamespace ?? fallbackNamespace) { config in
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

            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            } else {
                ListRowStatusIndicator(
                    status: game.status,
                    onStopImport: onStopImport
                )
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}


private struct ListRowStatusIndicator: View {
    let status: GameStatus
    var onStopImport: (() -> Void)? = nil

    private let size: CGFloat = AppSize.toolbarButton
    private let ringSize: CGFloat = 28
    private let lineWidth: CGFloat = 2.7
    private let stopSize: CGFloat = 9.5

    private var isImporting: Bool { status.phase == .importing }
    private var progress: Double {
        if case .importing(let p) = status { return p }
        return 0
    }

    var body: some View {
        ZStack {
            // Background circle — fills in on ready, hidden on invalid
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .opacity(status.phase == .ready ? 1 : 0)
                .scaleEffect(status.phase == .ready ? 1 : 0.7)

            SpinnerRing(
                progress: progress,
                size: ringSize,
                lineWidth: lineWidth,
                tint: .primary,
                trackOpacity: 0.2
            )
            .opacity(isImporting ? 1 : 0)
            .scaleEffect(isImporting ? 1 : 0.5)

            // Inner icon — stop square morphs to play or warning
            innerIcon
            .transition(.blurReplace)
        }
        .frame(width: size, height: size)
        .animation(Motion.gentle, value: status.phase)
    }

    @ViewBuilder
    private var innerIcon: some View {
        switch status.phase {
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
                .font(.caption)
                .foregroundStyle(.primary)
        case .invalid:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.warning)
        }
    }
}
