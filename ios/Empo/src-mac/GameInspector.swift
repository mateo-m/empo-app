// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        if let game = model.selectedGame {
            if game.status == .ready, let container = game.container {
                GameInfoForm(game: game, container: container, model: model)
                    .id(game.viewIdentity)
            } else {
                GameStatusView(game: game)
            }
        } else {
            ContentUnavailableView(
                "No Game Selected",
                systemImage: "info.circle",
                description: Text("Select a game to see its details.")
            )
        }
    }
}

private struct GameStatusView: View {
    let game: GameEntry

    var body: some View {
        VStack(spacing: Spacing.lg) {
            GameArtworkView(
                artworkPath: game.artworkPath,
                placeholderIconSize: IconSize.placeholder,
                size: 128,
                cornerRadius: Radius.lg,
                importing: game.isImporting,
                reloadToken: game.artworkRevision
            )
            .elevatedShadow()
            Text(game.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            switch game.status {
            case .invalid:
                Label(GameLibrary.whyInvalid(game), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .importing:
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Importing…")
                    PixelProgressBar(value: game.importProgress)
                }
            case .deleting:
                Text("Deleting…").foregroundStyle(.secondary)
            case .ready:
                EmptyView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GameInfoForm: View {
    let game: GameEntry
    let container: GameContainer
    let model: LibraryWindowModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.appSettings) private var settings
    @State private var hasCustomArtwork: Bool
    @State private var savedTitle: String?
    @State private var customTitle: String
    @State private var diskSize: Int64?
    @State private var runtimeRows: [InfoRow] = []
    @State private var isChoosingArtwork = false
    private let originalTitle: String
    private let madeWith: String?
    private let coreName: String?

    init(game: GameEntry, container: GameContainer, model: LibraryWindowModel) {
        self.game = game
        self.container = container
        self.model = model
        let metadata = GameMetadata.load(from: container)
        _hasCustomArtwork = State(initialValue: metadata.customArtworkFilename != nil)
        _savedTitle = State(initialValue: metadata.customTitle)
        _customTitle = State(initialValue: metadata.customTitle ?? "")
        let core = GameCores.core(forGameAt: container.gameURL)
        originalTitle =
            metadata.baseTitle ?? core?.defaultTitle(of: container) ?? String(localized: "Untitled game")
        madeWith = core?.madeWith(at: container.gameURL)
        coreName = core?.displayName
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: Spacing.lg) {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        placeholderIconSize: IconSize.placeholder,
                        size: 128,
                        cornerRadius: Radius.lg,
                        reloadToken: game.artworkRevision
                    )
                    .elevatedShadow()

                    Menu("Change Game Artwork") {
                        Button("Choose Image…") { isChoosingArtwork = true }
                        if hasCustomArtwork {
                            Button("Use Original Artwork", action: removeArtwork)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.link)
                    .fixedSize()

                    TextField("Title", text: $customTitle, prompt: Text(originalTitle))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.center)
                        .onSubmit(saveTitle)
                        .accessibilityLabel("Edit game title")

                    HStack {
                        Button("Play") { model.play(game) }
                            .buttonStyle(.borderedProminent)
                        Button("Game Settings…") { openWindow(id: GameSettingsWindow.id, value: game.id) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
            }

            Section("Details") {
                if let madeWith, let coreName {
                    LabeledContent("Made With", value: madeWith)
                    LabeledContent("Game Core", value: coreName)
                }
                LabeledContent("Date Added") {
                    Text(
                        game.dateAdded?.formatted(date: .abbreviated, time: .omitted)
                            ?? String(localized: "Unknown"))
                }
                LabeledContent("Last Played") {
                    TimelineView(.everyMinute) { _ in
                        Text(
                            game.lastPlayed?.formatted(.relative(presentation: .named))
                                ?? String(localized: "Never"))
                    }
                }
                if let playTime = game.totalPlayTime, playTime > 0 {
                    LabeledContent("Play Time", value: GameMetadata.formatPlayTime(playTime))
                }
                LabeledContent("Size on Disk") {
                    if let diskSize {
                        Text(GameMetadata.formatDiskSize(diskSize))
                    } else {
                        SpinnerRing(progress: 0, size: 15, tint: AnyShapeStyle(.secondary))
                    }
                }
                LabeledContent("Folder Name") {
                    Text(game.id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if settings.debugLogs, !runtimeRows.isEmpty {
                Section("Runtime") {
                    ForEach(runtimeRows) { row in
                        LabeledContent {
                            Text(row.value ?? String(localized: "Unknown")).monospaced()
                        } label: {
                            Text(row.label)
                        }
                    }
                }
            }

            Section {
                Button("Show in Finder", systemImage: "folder") { model.showInFinder(game) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isChoosingArtwork,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let image = NSImage(contentsOf: url) else { return }
            saveArtwork(image)
        }
        .onDisappear(perform: saveTitle)
        .task { diskSize = await GameMetadata.diskSize(for: container.url) }
        .task {
            guard settings.debugLogs, let core = GameCores.core(forGameAt: container.gameURL) else { return }
            runtimeRows = await core.infoRows(for: container)
        }
    }

    private func saveTitle() {
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.isEmpty ? nil : trimmed) != savedTitle else { return }
        savedTitle = GameMetadata.saveCustomTitle(customTitle, in: container).customTitle
        model.library.refreshGameEntry(id: game.id)
    }

    private func saveArtwork(_ image: NSImage) {
        guard GameMetadata.saveCustomImage(image, as: .artwork, in: container) != nil else { return }
        hasCustomArtwork = true
        didChangeImage()
    }

    private func removeArtwork() {
        GameMetadata.removeCustomImage(.artwork, in: container)
        hasCustomArtwork = false
        didChangeImage()
    }

    private func didChangeImage() {
        game.artworkRevision += 1
        model.library.refreshGameEntry(id: game.id)
    }
}
