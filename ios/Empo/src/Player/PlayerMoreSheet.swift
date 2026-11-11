// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import SwiftUI

/// A SwiftUI `List` always fills the sheet, so the rows are buttons in
/// a VStack, and the sheet height fits the content.
struct PlayerMoreSheet: View {
    let gameTitle: String?
    @Binding var showDebugOverlay: Bool
    @Binding var fastForwardActive: Bool
    let fastForwardMultiplier: Int?
    let showControllerRemap: Bool
    let onControllerRemap: () -> Void
    let onLayoutProfile: () -> Void
    let onPause: () -> Void
    /// Nil hides the Quit row, for a game that can't end without
    /// closing Empo.
    let onQuit: (() -> Void)?
    /// Nil hides the Show cheats row, for a game that has no cheats.
    let onCheats: (() -> Void)?

    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var sheetSize = IntrinsicSheetSize()
    @State private var confirmQuit = false

    private var pauseLabel: LocalizedStringResource {
        if let gameTitle { "Pause \(gameTitle)" } else { "Pause game" }
    }

    private var quitLabel: LocalizedStringResource {
        if let gameTitle { "Quit \(gameTitle)" } else { "Quit game" }
    }

    private var quitQuestion: LocalizedStringResource {
        if let gameTitle { "Quit \"\(gameTitle)\"?" } else { "Quit this game?" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.lg) {
                VStack(spacing: 0) {
                    InterleavedRows {
                        if let onCheats {
                            SheetRow(icon: "wand.and.stars", label: "Show cheats") {
                                onCheats()
                                dismiss()
                            }
                        }
                        if let multiplier = FastForwardArbiter.usableMultiplier(
                            fastForwardMultiplier)
                        {
                            MenuToggleRow(
                                icon: "hare.fill",
                                label: "Fast forward (\(multiplier)x)",
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
                        if showControllerRemap {
                            SheetRow(icon: "gamecontroller.fill", label: "Controller buttons") {
                                onControllerRemap()
                                dismiss()
                            }
                        }
                        SheetRow(icon: "square.on.square", label: "Layout profile") {
                            onLayoutProfile()
                            dismiss()
                        }
                    }
                }
                // A card fill on the material of the sheet shows as a
                // flat white panel.
                .clipShape(.rect(cornerRadius: Radius.md))

                VStack(spacing: 0) {
                    InterleavedRows {
                        SheetRow(icon: "pause.fill", label: pauseLabel) {
                            onPause()
                            dismiss()
                        }
                        if onQuit != nil {
                            SheetRow(icon: "xmark", label: quitLabel, role: .destructive) {
                                confirmQuit = true
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.md))
                .alert(quitQuestion, isPresented: $confirmQuit) {
                    Button("Cancel", role: .cancel) {}
                    Button("Quit", role: .destructive) {
                        onQuit?()
                        dismiss()
                    }
                } message: {
                    Text("Progress you haven't saved will be lost.")
                }
            }
            .padding(Spacing.xl)
            .intrinsicSheetContent(size: $sheetSize)
            // A solid background here shows as a flat white panel
            // over the game.
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetBarButton.done { dismiss() }
                }
            }
        }
        .intrinsicSheetDetent(size: $sheetSize)
    }
}

/// Puts a separator between the rows that show, and none next to a
/// row that a condition hides.
private struct InterleavedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            ForEach(rows) { row in
                if row.id != rows.first?.id {
                    SheetRowSeparator(leadingColumn: 24)
                }
                row
            }
        }
    }
}

private struct MenuToggleRow: View {
    let icon: String
    let label: LocalizedStringResource
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
