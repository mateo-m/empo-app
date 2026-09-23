import SwiftUI

/// To announce a release, add an entry at the top with the next
/// version. Copy the items from the Highlights section of
/// CHANGELOG.md.
enum WhatsNew {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: 1,
            items: [
                WhatsNewItem(
                    symbol: "gamecontroller",
                    title: "PSDK games",
                    detail: "Empo now plays games made with PSDK. Import one the same way "
                        + "you import an RPG Maker game."
                ),
                WhatsNewItem(
                    symbol: "slider.horizontal.3",
                    title: "Controls that fit the game",
                    detail: "Each game gets the on-screen buttons and the settings that its "
                        + "engine supports."
                ),
                WhatsNewItem(
                    symbol: "cpu",
                    title: "Game cores",
                    detail: "See the game cores built into Empo in Settings."
                ),
            ]
        )
    ]

    static let version = releases.map(\.version).max() ?? 0

    static let releasesURL = URL(string: "https://github.com/mateo-m/empo-app/releases")!

    /// The items of every release after `seenVersion`, newest first.
    static func items(
        after seenVersion: Int,
        in releases: [WhatsNewRelease] = releases
    ) -> [WhatsNewItem] {
        releases
            .filter { $0.version > seenVersion }
            .sorted { $0.version > $1.version }
            .flatMap(\.items)
    }
}

struct WhatsNewRelease {
    let version: Int
    let items: [WhatsNewItem]
}

struct WhatsNewItem {
    let symbol: String
    let title: String
    let detail: String
}

/// Shows the news once after an update. Any dismissal marks it as
/// read. A new install marks it as read when the user acknowledges
/// the disclaimer, so only updated installs see it.
struct WhatsNewPresentation: ViewModifier {
    /// False while the splash is still up.
    var active: Bool = true

    @Environment(\.appSettings) private var settings
    /// True when another one-time notice waits at launch. The news
    /// then waits for the next launch, because SwiftUI shows only
    /// one of two presentations that start together.
    @State private var otherNoticePending = true
    /// Read once, because the dismissal marks every item as read
    /// while the sheet still animates out.
    @State private var items: [WhatsNewItem] = []

    private var isPresented: Binding<Bool> {
        Binding(
            get: { active && !otherNoticePending && settings.needsWhatsNew },
            set: { presented in
                if !presented { settings.acknowledgeWhatsNew() }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .task {
                items = WhatsNew.items(after: settings.whatsNewSeenVersion)
                otherNoticePending =
                    !DataDirectory.pendingSaveRecoveries().isEmpty
                    || !GameContainerMigration.pendingDuplicateNoticeNames().isEmpty
            }
            .sheet(isPresented: isPresented) {
                WhatsNewSheet(items: items) { isPresented.wrappedValue = false }
            }
    }
}

struct WhatsNewSheet: View {
    let items: [WhatsNewItem]
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false

    var body: some View {
        StandardSheet(title: "What's new in \(AppInfo.name)", emblem: "sparkles") {
            VStack(alignment: .leading, spacing: Spacing._2xl) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    // Animate only the fade and the slide. An animation
                    // on the whole row also catches the layout pass of
                    // the opening sheet, and SwiftUI shows a moved Text
                    // as glyphs that fade across the gap.
                    WhatsNewRow(item: item)
                        .animation(Motion.standard.delay(0.1 + Double(index) * 0.1)) {
                            $0.opacity(entered ? 1 : 0)
                                .offset(y: entered || reduceMotion ? 0 : 8)
                        }
                }
            }
            .padding(.vertical, Spacing.md)

            VStack(spacing: 0) {
                SheetPrimaryButton("Continue", action: onContinue)

                Link(destination: WhatsNew.releasesURL) {
                    Text("See all changes on GitHub\u{00A0}\(Image(systemName: "arrow.up.forward"))")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("See all changes on GitHub")
                        .padding(.horizontal, Spacing.lg)
                        .frame(minHeight: AppSize.minTapTarget)
                        .contentShape(.rect)
                }
                .padding(.top, Spacing.sm)
            }
        }
        .onAppear { entered = true }
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At the accessibility text sizes, the icon goes above the text.
    /// The icon grows with the text and leaves no width beside it.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.lg))
    }

    var body: some View {
        layout {
            Image(systemName: item.symbol)
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(minWidth: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
