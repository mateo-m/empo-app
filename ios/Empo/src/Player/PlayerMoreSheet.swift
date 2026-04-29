import SwiftUI

/// Bottom sheet of secondary in-game actions reachable from the
/// player toolbar's "Menu" button. Houses options that don't earn a
/// permanent toolbar slot — pause, cheats, debug overlay, fast
/// forward, quit. Toggles update host state directly; tap actions
/// dismiss the sheet via `dismiss()` so the user lands back in the
/// game.
///
/// Sheet height fits content (measured via `onGeometryChange`),
/// matching the pattern used by `ImageSourceSheet` /
/// `ExperimentalInfoSheet`. A SwiftUI `List` would always want to
/// fill the sheet, so we render rows as styled `Button`s inside a
/// VStack with `.fixedSize(horizontal: false, vertical: true)`.
struct PlayerMoreSheet: View {
    /// Display title of the running game. Substituted into the
    /// destructive section's row labels ("Pause <title>" / "Quit
    /// <title>") so the user sees exactly what they're acting on.
    /// Falls back to "Game" if `selectedGame` is nil at present time.
    let gameTitle: String
    @Binding var showDebugOverlay: Bool
    @Binding var fastForwardActive: Bool
    /// Multiplier the user configured in Game Settings. nil means
    /// fast-forward is disabled for this game; the row is hidden.
    let fastForwardMultiplier: Int?
    let onPause: () -> Void
    let onCheats: () -> Void
    let onQuit: () -> Void

    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var measuredHeight: CGFloat = 0
    /// Nav bar + drag indicator + bottom safe-area padding above the
    /// measured content. Matches the value used by `ImageSourceSheet`.
    private let chromeAllowance: CGFloat = 64

    private var fastForwardEnabled: Bool {
        (fastForwardMultiplier ?? 0) >= 2
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                // Auxiliary toggles group — cheats, fast forward,
                // debug overlay. These are passive in-game tools; the
                // user can flip them and stay in the game.
                VStack(spacing: 0) {
                    InterleavedRows(separator: { rowSeparator }) {
                        if settings.isEnabled(.cheats) {
                            MenuRow(icon: "wand.and.stars", label: "Cheats menu") {
                                onCheats(); dismiss()
                            }
                        }
                        if fastForwardEnabled {
                            MenuToggleRow(
                                icon: "hare.fill",
                                label: "Fast forward (\(fastForwardMultiplier ?? 2)x)",
                                isOn: $fastForwardActive
                            )
                        }
                        if settings.debugMode {
                            MenuToggleRow(
                                icon: "ladybug.fill",
                                label: "Debug overlay",
                                isOn: $showDebugOverlay
                            )
                        }
                    }
                }
                // No card fill: stacking material on the sheet's own
                // material reads as a flat white panel, which fights
                // the translucent chrome the user expects from a
                // bottom sheet. The grouping still reads as a unit
                // because of the inter-row dividers and the gap
                // between this card and the destructive section
                // below.
                .clipShape(.rect(cornerRadius: Radius.md))

                // Session-ending actions grouped together — pause
                // takes the user back to the library (game stays
                // suspended), quit tears the engine down. Both name
                // the running game so there's no ambiguity about
                // which session is affected.
                let pauseEnabled = settings.isEnabled(.gamePause)
                let quitEnabled = settings.isEnabled(.gameQuit)
                if pauseEnabled || quitEnabled {
                    VStack(spacing: 0) {
                        InterleavedRows(separator: { rowSeparator }) {
                            if pauseEnabled {
                                MenuRow(
                                    icon: "pause.fill",
                                    label: "Pause \(gameTitle)"
                                ) {
                                    onPause(); dismiss()
                                }
                            }
                            if quitEnabled {
                                MenuRow(
                                    icon: "xmark.circle.fill",
                                    label: "Quit \(gameTitle)",
                                    role: .destructive
                                ) {
                                    dismiss(); onQuit()
                                }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: Radius.md))
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                measuredHeight = newHeight
            }
            // No outer background: the sheet's own translucent
            // material shows through around the row-cards. Painting a
            // solid `systemGroupedBackground` here looked like a flat
            // white panel hovering over the game and clashed with the
            // sheet chrome when extended past the measured height.
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents(
            measuredHeight > 0
                ? [.height(measuredHeight + chromeAllowance)]
                : [.medium]
        )
        .presentationDragIndicator(.visible)
    }

    /// Hairline separator between rows inside the action group.
    /// Indented past the icon column so it only spans the text area,
    /// matching the visual rhythm of UIKit grouped lists.
    private var rowSeparator: some View {
        Divider()
            .padding(.leading, Spacing.lg + 24 + Spacing.lg)
    }
}


/// Helper that interleaves `separator` between each emitted row of
/// the trailing `content` builder. Skips separators around
/// conditionally-omitted rows so the visual rhythm doesn't show
/// dangling dividers when a section is gated by a setting.
///
/// Uses `_VariadicView_Tree` to introspect the children produced by
/// the ViewBuilder closure; this is private SwiftUI but stable
/// enough for menu-style row layouts. Same trick used by
/// SwiftUI's own `Form` sections.
private struct InterleavedRows<Separator: View, Content: View>: View {
    @ViewBuilder var separator: () -> Separator
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(Layout(separator: separator)) {
            content()
        }
    }

    private struct Layout<Sep: View>: _VariadicView_MultiViewRoot {
        @ViewBuilder var separator: () -> Sep

        func body(children: _VariadicView.Children) -> some View {
            ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                if idx > 0 {
                    separator()
                }
                child
            }
        }
    }
}


/// Tappable row in `PlayerMoreSheet`. Layout matches
/// `ImageSourceSheet`'s `ImageSourceRow` (icon + label, full-row
/// hit target) but kept private to this file so the destructive
/// styling can diverge if needed.
private struct MenuRow: View {
    let icon: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Spacing.lg) {
                Image(systemName: icon)
                    .foregroundStyle(role == .destructive ? .red : .primary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(role == .destructive ? .red : .primary)
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
        }
    }
}


/// Toggle row in `PlayerMoreSheet`. Icon color matches the label
/// text rather than the system tint so it reads as one unit.
private struct MenuToggleRow: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.lg) {
                Image(systemName: icon)
                    .foregroundStyle(.primary)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }
}
