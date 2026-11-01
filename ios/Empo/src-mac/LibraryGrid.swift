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
                                .simultaneousGesture(TapGesture().onEnded { select(game) })
                                .contextMenu { GameContextMenu(game: game, model: model) }
                                .accessibilityAction { model.play(game) }
                                .accessibilityAction(named: "Select") { select(game) }
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
                    guard let game = model.selectedGame else { return .ignored }
                    model.play(game)
                    return .handled
                }
                .onDeleteCommand {
                    if let game = model.selectedGame { model.requestDelete(game) }
                }
            }
        }
    }

    private func select(_ game: GameEntry) {
        model.selection = game.id
        isFocused = true
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        placeholderIconSize: IconSize.placeholder,
                        cornerRadius: Radius.md,
                        importing: game.isImporting,
                        reloadToken: game.artworkRevision
                    )
                }
                .overlay {
                    if game.status == .invalid {
                        Color.black.opacity(Scrim.light)
                        InvalidGameBadge()
                            .font(.title)
                    }
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
                        .strokeBorder(selectionStyle, lineWidth: 3)
                        .padding(-4)
                }
                .cardShadow()
                .scaleEffect(isHovered && !game.isDeleting && !reduceMotion ? 1.02 : 1)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(game.isDeleting ? Alpha.disabled : 1)
        .contentShape(.rect)
        .onHover { hovering in
            withAnimation(Motion.snappy) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var selectionStyle: AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(.clear) }
        return isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.6))
    }

    private var subtitle: String? {
        if game.isImporting { return String(localized: "Importing…") }
        if game.isDeleting { return String(localized: "Deleting…") }
        return game.engineTitle
    }
}

struct InvalidGameBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.warning)
            .accessibilityLabel("This game won't open")
    }
}
