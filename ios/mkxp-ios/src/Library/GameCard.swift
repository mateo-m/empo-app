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

    // MARK: - Title Inside Card

    private var insideCard: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artworkView }
            .overlay(alignment: .bottom) {
                // Progressive blur sized to title
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
                        .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.leading)

                    if let originalTitle = game.originalTitle {
                        Text(originalTitle)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                            .lineLimit(1)
                    }
                }
                .padding(8)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    titleHeight = newHeight
                }
            }
            .overlay { centerOverlay }
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Title Under Card

    private var underCard: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { artworkView }
                .overlay { centerOverlay }
                .clipShape(.rect(cornerRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

            VStack(spacing: 2) {
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

    // MARK: - Shared

    @ViewBuilder
    private var centerOverlay: some View {
        switch game.status {
        case .importing:
            Color.black.opacity(0.3)
            ImportProgressView(progress: game.importProgress, onStop: onStopImport)
        case .invalid:
            Color.black.opacity(0.3)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        case .ready:
            if isPaused {
                // Paused indicator
                Color.black.opacity(0.35)
                Image(systemName: "pause.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
            } else {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
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

// MARK: - Import Progress Indicator

private struct ImportProgressView: View {
    let progress: Double
    var size: CGFloat = 36
    var tint: Color = .white
    var onStop: (() -> Void)? = nil
    @State private var spinning = false

    private var isDeterminate: Bool { progress > 0 }
    private var lineWidth: CGFloat { size * 0.097 }
    private var stopSize: CGFloat { size * 0.333 }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: lineWidth)
                .frame(width: size, height: size)

            if isDeterminate {
                // Determinate: radial fill
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
            } else {
                // Indeterminate: spinning arc
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear { spinning = true }
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            }

            // Stop button
            Button(action: { onStop?() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: stopSize, height: stopSize)
            }
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

// MARK: - Game List Row

struct GameListRow: View {
    let game: GameEntry
    var isPaused: Bool = false
    var heroNamespace: Namespace.ID? = nil
    var onStopImport: (() -> Void)? = nil
    private let artworkSize: CGFloat = 48

    // Fallback namespace keeps the view tree stable when heroNamespace
    // is nil (importing state).  Without this, the conditional .if()
    // modifier was creating two structural branches — SwiftUI destroyed
    // and recreated GameArtworkView on status change, losing @State and
    // preventing the saturation animation.
    @Namespace private var fallbackNamespace

    var body: some View {
        HStack(spacing: 14) {
            // Artwork thumbnail
            GameArtworkView(
                artworkPath: game.artworkPath,
                placeholderIconSize: 16,
                size: artworkSize,
                cornerRadius: 8,
                importing: game.status.phase == .importing
            )
            .matchedTransitionSource(id: game.id, in: heroNamespace ?? fallbackNamespace) { config in
                config
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 8))
            }

            // Title and original name
            VStack(alignment: .leading, spacing: 2) {
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

            // Status indicator (morphs between states)
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
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
        .listRowBackground(Color(.systemBackground))
    }
}

// MARK: - List Row Status Indicator (Morphing)

/// Animates between importing → ready/invalid with a shared circle that morphs.
private struct ListRowStatusIndicator: View {
    let status: GameStatus
    var onStopImport: (() -> Void)? = nil

    @State private var spinning = false
    private let size: CGFloat = 38
    private let ringSize: CGFloat = 28
    private let lineWidth: CGFloat = 2.7
    private let stopSize: CGFloat = 9.5

    private var isImporting: Bool { status.phase == .importing }
    private var progress: Double {
        if case .importing(let p) = status { return p }
        return 0
    }
    private var isDeterminate: Bool { progress > 0 }

    var body: some View {
        ZStack {
            // Background circle — fills in on ready, hidden on invalid
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .opacity(status.phase == .ready ? 1 : 0)
                .scaleEffect(status.phase == .ready ? 1 : 0.7)

            // Progress ring — visible only while importing
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)
                    .frame(width: ringSize, height: ringSize)

                if isDeterminate {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .onAppear { spinning = true }
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                }
            }
            .opacity(isImporting ? 1 : 0)
            .scaleEffect(isImporting ? 1 : 0.5)

            // Inner icon — stop square morphs to play or warning
            Group {
                switch status.phase {
                case .importing:
                    Button(action: { onStopImport?() }) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.primary)
                            .frame(width: stopSize, height: stopSize)
                    }
                    .buttonStyle(.plain)
                case .ready:
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                case .invalid:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            .transition(.blurReplace)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: progress)
        .animation(.smooth(duration: 0.4), value: status.phase)
    }
}

// MARK: - Card Press Style

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
