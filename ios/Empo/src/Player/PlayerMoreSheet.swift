import SwiftUI

/// Bottom sheet of secondary in-game actions reachable from the
/// player toolbar's "Menu" button. Houses options that don't earn a
/// permanent toolbar slot; pause, cheats, debug overlay, fast
/// forward, quit. Toggles update host state directly; tap actions
/// dismiss the sheet via `dismiss()` so the user lands back in the
/// game.
///
/// Sheet height fits content (measured via `onGeometryChange`).
/// A SwiftUI `List` always wants to fill the sheet, so rows are
/// styled `Button`s inside a VStack with
/// `.fixedSize(horizontal: false, vertical: true)`.
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

    private var fastForwardEnabled: Bool {
        (fastForwardMultiplier ?? 0) >= 2
    }

    /// Whether the sheet would render any actionable row given the
    /// current settings + per-game state. Mirrors the row-gating
    /// logic in `body` exactly.
    ///
    /// Used by `PlayerToolbar` to hide the Menu button when this
    /// returns false - otherwise the toolbar offers a button that
    /// opens an empty sheet, which has been confusing users who
    /// disable all the experimental features in app settings.
    static func hasContent(
        settings: AppSettings,
        fastForwardMultiplier: Int?
    ) -> Bool {
        // Cheats and pause graduated from experimental in May 2026
        // and are now always enabled. Diagnostics overlay and
        // fast-forward remain user-gated (the former via app
        // settings, the latter per-game).
        let cheats = true
        let fastFwd = (fastForwardMultiplier ?? 0) >= 2
        let diag = settings.diagnosticsOverlay
        let pause = true
        // gameQuit is currently forced off in `body`; if/when it
        // returns, mirror its gate here.
        return cheats || fastFwd || diag || pause
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                // Auxiliary toggles group; cheats, fast forward,
                // debug overlay. These are passive in-game tools; the
                // user can flip them and stay in the game.
                VStack(spacing: 0) {
                    InterleavedRows(
                        separator: { rowSeparator },
                        content: {
                            // Cheats: graduated from experimental in
                            // May 2026, always enabled now.
                            MenuRow(icon: "wand.and.stars", label: "Cheats") {
                                onCheats()
                                dismiss()
                            }
                            if fastForwardEnabled {
                                MenuToggleRow(
                                    icon: "hare.fill",
                                    label: "Fast forward (\(fastForwardMultiplier ?? 2)x)",
                                    isOn: $fastForwardActive
                                )
                            }
                            if settings.diagnosticsOverlay {
                                MenuToggleRow(
                                    icon: "ladybug.fill",
                                    label: "Diagnostics overlay",
                                    isOn: $showDebugOverlay
                                )
                            }
                        }
                    )
                }
                // No card fill: stacking material on the sheet's own
                // material reads as a flat white panel, which fights
                // the translucent chrome the user expects from a
                // bottom sheet. The grouping still reads as a unit
                // because of the inter-row dividers and the gap
                // between this card and the destructive section
                // below.
                .clipShape(.rect(cornerRadius: Radius.md))

                // Session-ending actions grouped together; pause
                // takes the user back to the library (game stays
                // suspended), quit tears the engine down. Both name
                // the running game so there's no ambiguity about
                // which session is affected.
                // Pause: graduated from experimental in May 2026,
                // always enabled now.
                let pauseEnabled = true
                // gameQuit disabled; see ExperimentalFeature comment
                // in AppSettings.swift. Forced false so the in-game
                // Quit toolbar button stays hidden.
                let quitEnabled = false
                if pauseEnabled || quitEnabled {
                    VStack(spacing: 0) {
                        InterleavedRows(
                            separator: { rowSeparator },
                            content: {
                                if pauseEnabled {
                                    MenuRow(
                                        icon: "pause.fill",
                                        label: "Pause \(gameTitle)"
                                    ) {
                                        onPause()
                                        dismiss()
                                    }
                                }
                                if quitEnabled {
                                    MenuRow(
                                        icon: "xmark.circle.fill",
                                        label: "Quit \(gameTitle)",
                                        role: .destructive
                                    ) {
                                        dismiss()
                                        onQuit()
                                    }
                                }
                            }
                        )
                    }
                    .clipShape(.rect(cornerRadius: Radius.md))
                }
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(measuredHeight: $measuredHeight)
            // No outer background: the sheet's translucent material
            // shows through around the row-cards. Painting a solid
            // `systemGroupedBackground` here looked like a flat white
            // panel hovering over the game.
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .intrinsicSheetDetent(measuredHeight: measuredHeight)
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
    var role: ButtonRole?
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
