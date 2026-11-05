// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct GameCoresView: View {
    private let cores = GameCores.inThisBuild

    private var tools: [(key: String, value: [any GameCore])] {
        Dictionary(grouping: cores, by: \.madeWith).sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            Section {
                if cores.isEmpty {
                    Text("This build has no game core.")
                        .foregroundStyle(.secondary)
                }

                ForEach(tools, id: \.key) { tool, cores in
                    DisclosureGroup(tool) {
                        ForEach(cores, id: \.framework) { core in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(core.displayName)
                                Text(core.gamesLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // Under RootView's `.fontDesign(.rounded)`, only
                                // `Font.monospaced()` stays fixed-width.
                                // `Text.monospaced()` and `.system(design: .monospaced)` render rounded.
                                Text("Built from \(core.version)")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, Spacing.xxs)
                        }
                    }
                }
            } footer: {
                Text(
                    "Each core runs the games named under it. Empo picks the core a game needs when you start it."
                )
            }
        }
        #if os(iOS)
        .navigationTitle("Game cores")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle("Game Cores")
        #endif
    }
}
