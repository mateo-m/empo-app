// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import SwiftUI

struct LibraryWindow: View {
    @State private var model = LibraryWindowModel()
    @State private var isDropTargeted = false
    @Environment(\.appSettings) private var settings

    var body: some View {
        @Bindable var model = model
        @Bindable var settings = settings
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if isDropTargeted { DropHighlight() } }
            .dropDestination(for: URL.self) { urls, _ in
                model.importGames(urls)
                return true
            } isTargeted: {
                isDropTargeted = $0
            }
            .navigationTitle("Library")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search games")
            .toolbar { toolbar }
            .inspector(isPresented: $model.showsInspector) {
                GameInspector(model: model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .fileImporter(
                isPresented: $model.showsImporter,
                allowedContentTypes: LibraryWindowModel.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { model.importGames(urls) }
            }
            .modifier(LibraryAlerts(model: model))
            .sheet(item: importPromptBinding) { prompt in
                ImportChoiceSheet(
                    prompt: prompt,
                    onCancel: model.importPipeline.cancelChoice,
                    onConfirm: model.importPipeline.confirmChoice(_:approvedUpdateIDs:))
            }
            .focusedSceneValue(\.libraryWindow, model)
            .onChange(of: settings.librarySortOption, initial: true) { model.refreshSizesIfNeeded() }
            .onChange(of: model.library.games.count) { model.refreshSizesIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.library.initialScanCompleted {
            ProgressView()
        } else if model.library.games.isEmpty && model.library.pendingImports.isEmpty {
            EmptyLibraryView { model.showsImporter = true }
        } else if model.games.isEmpty {
            ContentUnavailableView.search(text: model.search)
        } else {
            switch settings.libraryDisplayMode {
            case .grid: LibraryGrid(model: model)
            case .list: LibraryTable(model: model)
            }
        }
    }

    private var subtitle: String {
        let count = model.library.games.count
        return count == 0
            ? ""
            : String(
                localized: "\(count) games", comment: "Window subtitle: the number of games in the library.")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var settings = settings
        ToolbarItem(placement: .navigation) {
            Button("Import Games…", systemImage: "plus") { model.showsImporter = true }
                .help("Import a game folder or archive")
        }
        ToolbarItemGroup {
            Picker("View", selection: $settings.libraryDisplayMode) {
                Label("Grid", systemImage: "square.grid.2x2").tag(LibraryDisplayMode.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryDisplayMode.list)
            }
            .pickerStyle(.segmented)
            .help("Show games as a grid or a list")

            Menu("Sort by", systemImage: "arrow.up.arrow.down") {
                Picker("Sort by", selection: $settings.librarySortOption) {
                    ForEach(LibrarySortOption.groups) { group in
                        Section {
                            ForEach(group.options, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
                .pickerStyle(.inline)
            }
            .help("Sort games")
        }
    }

    private var importPromptBinding: Binding<ImportRootPrompt?> {
        Binding(
            get: { model.importPipeline.activePrompt },
            set: { if $0 == nil { model.importPipeline.dismissPrompt() } }
        )
    }
}

private struct EmptyLibraryView: View {
    let onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("No games yet")
            } icon: {
                Image(.empoMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.brand)
            }
        } description: {
            Text("Import a game folder or archive, or drag one into this window.")
        } actions: {
            Button("Import Games…", action: onImport)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: Radius.md))
            .overlay {
                Label("Drop to import", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .background(.regularMaterial, in: .capsule)
            }
            .padding(Spacing.md)
            .allowsHitTesting(false)
    }
}

private struct LibraryAlerts: ViewModifier {
    @Bindable var model: LibraryWindowModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete this game?",
                isPresented: isPresented($model.gameToDelete),
                presenting: model.gameToDelete
            ) { game in
                Button("Delete", role: .destructive) { model.delete(game) }
                Button("Cancel", role: .cancel) {}
            } message: { game in
                if game.isImporting {
                    Text(
                        "This stops importing \"\(game.title)\". If you were updating a game you already have, that copy stays as it is."
                    )
                } else {
                    Text(
                        "This deletes \"\(game.title)\" from your device. Empo moves the saves it recognizes to Rescued Saves. Saves it doesn't recognize are deleted with the game. You can't undo this."
                    )
                }
            }
            .alert(
                "Couldn't move the saves",
                isPresented: Binding(
                    get: { !model.saveRescueFailures.isEmpty },
                    set: {
                        if !$0, !model.saveRescueFailures.isEmpty { model.saveRescueFailures.removeFirst() }
                    }
                ),
                presenting: model.saveRescueFailures.first
            ) { game in
                Button("Delete anyway", role: .destructive) { model.delete(game, discardingSaves: true) }
                Button("Keep game", role: .cancel) {}
            } message: { game in
                Text(
                    "Empo couldn't move the saves for \"\(game.title)\" to Rescued Saves. Free up space and delete again, or delete now and lose those saves. You can't undo this."
                )
            }
            .alert(
                model.warnedLaunch?.warning.title ?? "",
                isPresented: isPresented($model.warnedLaunch),
                presenting: model.warnedLaunch
            ) { warned in
                Button(warned.warning.confirm) { model.launch(warned.game) }
                Button("Cancel", role: .cancel) {}
            } message: { warned in
                Text(warned.warning.message)
            }
            .alert(
                "Empo can't run this game",
                isPresented: isPresented($model.launchFailure),
                presenting: model.launchFailure
            ) { _ in
                Button("Got it") {}
            } message: { failure in
                Text(failure.message)
            }
            .modifier(ImportAlerts(model: model))
    }
}

private struct ImportAlerts: ViewModifier {
    @Bindable var model: LibraryWindowModel

    func body(content: Content) -> some View {
        content
            .alert(
                model.deleteFailure?.title ?? "",
                isPresented: isPresented($model.deleteFailure),
                presenting: model.deleteFailure
            ) { _ in
                Button("Got it") {}
            } message: { failure in
                Text(failure.message)
            }
            .alert(
                model.importPipeline.alert?.title ?? "",
                isPresented: Binding(
                    get: { model.importPipeline.alert != nil },
                    set: { if !$0 { model.importPipeline.dismissAlert() } }
                ),
                presenting: model.importPipeline.alert
            ) { _ in
                Button("Got it") {}
            } message: { alert in
                Text(alert.message)
            }
            .alert(
                replaceTitle,
                isPresented: Binding(
                    get: { model.importPipeline.activeReplacePrompt != nil },
                    set: { if !$0 { model.importPipeline.dismissReplacePrompt() } }
                ),
                presenting: model.importPipeline.activeReplacePrompt
            ) { _ in
                Button("Update", role: .destructive) { model.importPipeline.confirmReplace() }
                Button("Cancel", role: .cancel) { model.importPipeline.cancelReplace() }
            } message: { prompt in
                Text(replaceMessage(for: prompt))
            }
    }

    private var replaceTitle: String {
        (model.importPipeline.activeReplacePrompt?.titles.count ?? 1) > 1
            ? String(localized: "These games are already in your library")
            : String(localized: "This game is already in your library")
    }

    private func replaceMessage(for prompt: ImportReplacePrompt) -> String {
        if prompt.titles.count == 1, let name = prompt.titles.first {
            return String(
                localized:
                    "\"\(name)\" is already in your library. Importing replaces its files with the new ones. Your saves and settings stay. You can't undo this.",
                comment: "The placeholder is the game's name."
            )
        }
        let names = prompt.titles.map { "\"\($0)\"" }.formatted(.list(type: .and))
        return String(
            localized:
                "\(names) are already in your library. Importing replaces their files with the new ones. Your saves and settings stay. You can't undo this.",
            comment: "The placeholder is a list of game names."
        )
    }
}

private func isPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}
