// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameInspector: View {
    let model: LibraryWindowModel

    var body: some View {
        if let game = model.selectedReadyGame, let container = game.container {
            GameInfoForm(game: game, container: container, model: model)
                .id(game.viewIdentity)
        } else {
            ContentUnavailableView(
                "No game selected",
                systemImage: "info.circle",
                description: Text("Select a game to see its details.")
            )
        }
    }
}

private struct GameInfoForm: View {
    let game: GameEntry
    let container: GameContainer
    let model: LibraryWindowModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.appSettings) private var settings
    @State private var metadata: GameMetadata
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
        _metadata = State(initialValue: metadata)
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
                        artworkPath: metadata.customArtworkPath(in: container) ?? game.artworkPath,
                        placeholderIconSize: 48,
                        size: 128,
                        cornerRadius: Radius.lg,
                        reloadToken: game.artworkRevision
                    )
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

                    Menu("Change game artwork") {
                        Button("Choose image…") { isChoosingArtwork = true }
                        if metadata.customArtworkFilename != nil {
                            Button("Use original artwork", action: removeArtwork)
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
                    LabeledContent("Made with", value: madeWith)
                    LabeledContent("Game core", value: coreName)
                }
                LabeledContent("Date added") {
                    Text(
                        metadata.dateAdded?.formatted(date: .abbreviated, time: .omitted)
                            ?? String(localized: "Unknown"))
                }
                LabeledContent("Last played") {
                    TimelineView(.everyMinute) { _ in
                        Text(
                            metadata.lastPlayed?.formatted(.relative(presentation: .named))
                                ?? String(localized: "Never"))
                    }
                }
                LabeledContent("Play time", value: GameMetadata.formatPlayTime(metadata.totalPlayTime))
                LabeledContent("Size on disk") {
                    if let diskSize {
                        Text(GameMetadata.formatDiskSize(diskSize))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("Folder name") {
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
        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = title.isEmpty ? nil : title
        guard newValue != metadata.customTitle else { return }
        metadata.customTitle = newValue
        metadata.save(to: container)
        model.library.refreshGameEntry(id: game.id)
    }

    private func saveArtwork(_ image: NSImage) {
        if let path = metadata.customArtworkPath(in: container) { ImageCache.shared.evict(path: path) }
        guard let filename = GameMetadata.saveImage(image, as: "artwork", in: container) else { return }
        metadata.customArtworkFilename = filename
        metadata.save(to: container)
        // A new image keeps the old file name. Evict again after the write
        // to drop a load that read the old bytes in the meantime.
        if let path = metadata.customArtworkPath(in: container) { ImageCache.shared.evict(path: path) }
        didChangeImage()
    }

    private func removeArtwork() {
        if let path = metadata.customArtworkPath(in: container) { ImageCache.shared.evict(path: path) }
        if let filename = metadata.customArtworkFilename {
            GameMetadata.removeImage(named: filename, in: container)
        }
        metadata.customArtworkFilename = nil
        metadata.save(to: container)
        didChangeImage()
    }

    private func didChangeImage() {
        game.artworkRevision += 1
        model.library.refreshGameEntry(id: game.id)
    }
}
