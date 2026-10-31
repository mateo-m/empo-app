// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

/// To announce a release, add an entry at the top of WhatsNew.json
/// with the next `version` and the app version that ships it. Add its
/// title and detail, with their translations, to
/// Resources/WhatsNew.xcstrings: the rows look them up by their English text.
enum WhatsNew {
    static let releases: [WhatsNewRelease] = {
        let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "json")!
        return try! JSONDecoder().decode([WhatsNewRelease].self, from: Data(contentsOf: url))
    }()

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

struct WhatsNewRelease: Decodable {
    let version: Int
    let items: [WhatsNewItem]
}

struct WhatsNewItem: Decodable {
    let symbol: String
    let title: String
    let detail: String
    var settingsSection: SettingsSection?
}

/// Shows the news once after an update. Any dismissal marks it as
/// read. A new install marks it as read when the user acknowledges
/// the disclaimer, so only updated installs see it.
struct WhatsNewPresentation: ViewModifier {
    /// False while the splash is still up.
    var active: Bool = true
    let onOpenSettings: (SettingsSection) -> Void

    @Environment(\.appSettings) private var settings
    /// True when another one-time notice waits at launch. The news
    /// then waits for the next launch, because SwiftUI shows only
    /// one of two presentations that start together.
    @State private var otherNoticePending = true
    /// Read once, because the dismissal marks every item as read
    /// while the sheet still animates out.
    @State private var items: [WhatsNewItem] = []
    /// Settings opens after the sheet is gone, because SwiftUI shows
    /// no new sheet while another one animates out.
    @State private var settingsToOpen: SettingsSection?

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
            .sheet(
                isPresented: isPresented,
                onDismiss: {
                    if let settingsToOpen { onOpenSettings(settingsToOpen) }
                    settingsToOpen = nil
                },
                content: {
                    WhatsNewSheet(
                        items: items,
                        onOpenSettings: { section in
                            settingsToOpen = section
                            isPresented.wrappedValue = false
                        },
                        onContinue: { isPresented.wrappedValue = false }
                    )
                }
            )
    }
}

struct WhatsNewSheet: View {
    let items: [WhatsNewItem]
    let onOpenSettings: (SettingsSection) -> Void
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
                    WhatsNewRow(item: item, onOpenSettings: onOpenSettings)
                        .animation(Motion.standard.delay(0.1 + Double(index) * 0.1)) {
                            $0.opacity(entered ? 1 : 0)
                                .offset(y: entered || reduceMotion ? 0 : 8)
                        }
                }
            }
            .padding(.vertical, Spacing.md)
        } footer: {
            SheetPrimaryButton("Continue", action: onContinue)

            Link(destination: WhatsNew.releasesURL) {
                Text(
                    "See all changes on GitHub\u{00A0}\(Image(systemName: "arrow.up.forward"))",
                    comment:
                        "Link to the release notes. The placeholder is an arrow icon. Keep it at the end."
                )
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .accessibilityLabel("See all changes on GitHub")
                .padding(.horizontal, Spacing.lg)
                .frame(minHeight: AppSize.minTapTarget)
                .contentShape(.rect)
            }
            .padding(.top, Spacing.sm)
        }
        .onAppear { entered = true }
    }
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem
    let onOpenSettings: (SettingsSection) -> Void

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
                Text(Bundle.main.localizedString(forKey: item.title, value: nil, table: "WhatsNew"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(Bundle.main.localizedString(forKey: item.detail, value: nil, table: "WhatsNew"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let section = item.settingsSection, section.isShown {
                    Button("Turn it on in Settings") { onOpenSettings(section) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: AppSize.minTapTarget)
                        .contentShape(.rect)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
