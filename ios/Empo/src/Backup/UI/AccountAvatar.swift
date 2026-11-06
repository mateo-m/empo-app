import GameProbe
import SwiftUI

/// The account photo of a location with a small service badge, or the
/// service icon alone when the service gives no photo or the photo
/// does not load.
struct AccountAvatar: View {

    let photo: URL?
    let provider: BackupProviderKind
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: photo) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    .overlay(alignment: .topTrailing) { badge }
            } else {
                serviceIcon(size: size * 0.5)
                    .frame(width: size, height: size)
                    .background(
                        provider.markName == nil
                            ? Color.brand.opacity(0.12) : Color(.tertiarySystemFill),
                        in: .circle)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var badge: some View {
        let side = size * 0.46
        return serviceIcon(size: side * 0.62)
            .frame(width: side, height: side)
            .background(Color(.secondarySystemGroupedBackground), in: .circle)
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            .offset(x: side * 0.25, y: -side * 0.25)
    }

    @ViewBuilder private func serviceIcon(size: CGFloat) -> some View {
        if let mark = provider.markName {
            Image(mark).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbolName)
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundStyle(.brand)
        }
    }
}
