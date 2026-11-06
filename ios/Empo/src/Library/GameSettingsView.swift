// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct GameSettingsView: View {
    let game: GameEntry
    @Environment(\.dismiss) private var dismiss
    /// Tells whether this game is paused in the background. Launch-time
    /// settings do not reach a paused game, so the sheet then shows a
    /// "restart required" hint after an edit.
    @Environment(\.pauseManager) private var pauseManager
    @Environment(\.appState) private var appState

    @State private var model: GameSettingsModel

    init(game: GameEntry) {
        self.game = game
        _model = State(initialValue: GameSettingsModel(game: game))
    }

    private var restartHint: Hint? {
        guard pauseManager.pausedGame?.id == game.id, let launched = appState.launchedSettings,
            let excerpt = model.restartHint(since: launched)
        else { return nil }
        return Hint(
            id: "gameSettings.restartRequired",
            excerpt: excerpt,
            description: nil,
            dismissal: .none,
            icon: "arrow.clockwise.circle.fill"
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                model.core?.settingsPage(model)

                ResetSettingsSection(model: model, gameTitle: game.title)
            }
            // Pin the restart-required pill above the form via a
            // top safe-area inset. The inset gives the pill a
            // z-order above the scrolling rows at no extra cost. We don't
            // try to paint a wide backdrop in the inset's
            // surrounding area because that only produces a
            // visible white/gray panel in light mode (regardless
            // of whether we use material, color, or a blend of
            // both).
            //
            // The pill itself gets a `.regularMaterial` fill
            // clipped to the same rounded shape `HintBanner`
            // already uses internally. It is translucent so form
            // rows scrolling past show through with a blur, yet
            // opaque enough that hint text doesn't visibly
            // collide with row labels underneath. The pill's own
            // brand-tinted layer (`.brand.opacity(0.1)` from
            // `HintBanner`) renders on top of the material, giving
            // the floating pill its brand cast.
            //
            // Slide+blur transition matches `.hintBanner` (same
            // one used by GameInfoView's customization hint). We
            // animate on the boolean (not the excerpt) so adding
            // or removing individual fields updates the text in
            // place without re-running the slide-in transition.
            // Only true appear/disappear cycles trigger movement.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let hint = restartHint {
                    HintBanner(hint: hint)
                        .background(
                            .regularMaterial,
                            in: PixelRect(cornerRadius: Radius.md)
                        )
                        .padding(.horizontal, Spacing._2xl)
                        .padding(.vertical, Spacing.md)
                        .transition(.hintBanner)
                }
            }
            .animation(.smooth(duration: 0.25), value: restartHint != nil)
            .navigationBarTitleDisplayMode(.inline)
            .sheetToolbar {
                VStack(spacing: 1) {
                    Text(game.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Settings")
                        .font(.headline)
                }
            } done: {
                dismiss()
            }
            .onChange(of: model.settings) { model.save() }
            // A quick dismissal can tear the sheet down in the same
            // update as the last toggle change. SwiftUI then drops
            // that onChange delivery, and the change never reaches
            // disk. Save once more on the way out.
            .onDisappear { model.save() }
        }
        .tint(.brand)
    }

}
