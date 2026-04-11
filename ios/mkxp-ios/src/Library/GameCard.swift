import SwiftUI

struct GameCard: View {
    let game: GameEntry
    var onStopImport: (() -> Void)? = nil
    @State private var titleHeight: CGFloat = 40

    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        switch settings.titlePosition {
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
                Text(game.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.leading)
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

            Text(game.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var centerOverlay: some View {
        if game.isImporting {
            Color.black.opacity(0.3)
            ImportProgressView(progress: game.importProgress, onStop: onStopImport)
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
                                colors: [.white, .white.opacity(0.7), .white.opacity(0.3), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 36
                            )
                        )
                        .frame(width: 72, height: 72)
                )
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let path = game.artworkPath, let uiImage = ImageCache.shared.image(for: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(.tertiarySystemBackground)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

// MARK: - Import Progress Indicator

private struct ImportProgressView: View {
    let progress: Double
    var onStop: (() -> Void)? = nil
    @State private var spinning = false

    private var isDeterminate: Bool { progress > 0 }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 3.5)
                .frame(width: 36, height: 36)

            if isDeterminate {
                // Determinate: radial fill
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            } else {
                // Indeterminate: spinning arc
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .onAppear { spinning = true }
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            }

            // Stop button
            Button(action: { onStop?() }) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
        }
        .animation(.easeOut(duration: 0.3), value: progress)
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
