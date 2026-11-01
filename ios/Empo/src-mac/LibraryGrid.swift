// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LibraryGrid: View {
    @Bindable var model: LibraryWindowModel
    @FocusState private var isFocused: Bool

    private let minimumCardWidth: CGFloat = 160
    private let spacing: CGFloat = Spacing._2xl
    private let padding: CGFloat = Spacing._2xl

    var body: some View {
        GeometryReader { proxy in
            let games = model.games
            let columnCount = max(
                1, Int((proxy.size.width - padding * 2 + spacing) / (minimumCardWidth + spacing)))
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
                        alignment: .leading,
                        spacing: spacing
                    ) {
                        ForEach(games, id: \.viewIdentity) { game in
                            GameCard(game: game, isSelected: model.selection == game.id, isFocused: isFocused)
                                .gesture(TapGesture(count: 2).onEnded { model.play(game) })
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        model.selection = game.id
                                        isFocused = true
                                    }
                                )
                                .contextMenu { GameContextMenu(game: game, model: model) }
                        }
                    }
                    .padding(padding)
                }
                .contentShape(.rect)
                .onTapGesture { model.selection = nil }
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let step =
                        switch press.key {
                        case .leftArrow: -1
                        case .rightArrow: 1
                        case .upArrow: -columnCount
                        default: columnCount
                        }
                    moveSelection(by: step, in: games, scroller: scroller)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let game = model.selectedReadyGame else { return .ignored }
                    model.play(game)
                    return .handled
                }
                .onDeleteCommand {
                    if let game = model.selectedGame { model.requestDelete(game) }
                }
            }
        }
    }

    private func moveSelection(by step: Int, in games: [GameEntry], scroller: ScrollViewProxy) {
        guard !games.isEmpty else { return }
        let current = games.firstIndex { $0.id == model.selection }
        let next =
            if let current {
                min(max(current + step, 0), games.count - 1)
            } else {
                0
            }
        model.selection = games[next].id
        scroller.scrollTo(games[next].viewIdentity)
    }
}

private struct GameCard: View {
    let game: GameEntry
    let isSelected: Bool
    let isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        placeholderIconSize: 44,
                        cornerRadius: Radius.md,
                        importing: game.isImporting,
                        reloadToken: game.artworkRevision
                    )
                }
                .clipShape(.rect(cornerRadius: Radius.md))
                .overlay(alignment: .bottom) {
                    if game.isImporting {
                        ProgressView(value: game.importProgress)
                            .progressViewStyle(.linear)
                            .padding(Spacing.md)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md + 4)
                        .strokeBorder(selectionColor, lineWidth: 3)
                        .padding(-4)
                }
                .shadow(
                    color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 8 : 3,
                    y: isHovered ? 4 : 1
                )
                .scaleEffect(isHovered && !game.isDeleting ? 1.02 : 1)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                TimelineView(.everyMinute) { _ in
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(game.isDeleting ? 0.4 : 1)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(Motion.snappy) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var selectionColor: Color {
        guard isSelected else { return .clear }
        return isFocused ? .accentColor : .secondary.opacity(0.6)
    }

    private var subtitle: String {
        if game.isImporting { return String(localized: "Importing…") }
        if game.isDeleting { return String(localized: "Deleting…") }
        if let engineTitle = game.engineTitle { return engineTitle }
        if let lastPlayed = game.lastPlayed {
            return lastPlayed.formatted(.relative(presentation: .named))
        }
        return String(localized: "Not played yet")
    }
}
