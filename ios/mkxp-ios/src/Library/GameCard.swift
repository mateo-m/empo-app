import SwiftUI

struct GameCard: View {
    let game: GameEntry
    @ObservedObject private var settings = AppSettings.shared
    @State private var titleHeight: CGFloat = 40

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
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Title Under Card

    private var underCard: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { artworkView }
                .overlay { centerOverlay }
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.3)
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
        if let path = game.artworkPath, let uiImage = UIImage(contentsOfFile: path) {
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
