// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryWindow: View {
    @State private var model = LibraryWindowModel()
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool
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
            .searchFocused($isSearchFocused)
            .toolbar { toolbar }
            .inspector(isPresented: $model.showsInspector) {
                GameInspector(model: model)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .fileImporter(
                isPresented: $model.showsImporter,
                allowedContentTypes: UTType.importableGames,
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
            .focusedSceneValue(\.isSearchingLibrary, isSearchFocused)
            .tint(.brand)
            .onChange(of: settings.librarySortOption, initial: true) { model.refreshSizesIfNeeded() }
            .onChange(of: model.library.readyGameIDs) { model.refreshSizesIfNeeded() }
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

            Menu("Sort By", systemImage: "arrow.up.arrow.down") {
                Picker("Sort By", selection: $settings.librarySortOption) {
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
                Text("No Games Yet")
            } icon: {
                Image(.empoMark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: IconSize.emptyState, height: IconSize.emptyState)
                    .foregroundStyle(.secondary)
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
            .strokeBorder(.tint, lineWidth: 3)
            .background(.tint.opacity(0.08), in: .rect(cornerRadius: Radius.md))
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
    @Bindable private var launcher = GameLauncher.shared

    func body(content: Content) -> some View {
        content
            .modifier(
                DeleteGameAlerts(
                    isPresented: isPresented($model.gameToDelete),
                    game: model.gameToDelete,
                    saveRescueFailures: $model.saveRescueFailures,
                    onDelete: { model.delete($0) },
                    onDeleteDiscardingSaves: { model.delete($0, discardingSaves: true) }
                )
            )
            .modifier(
                StopValidationAlert(
                    isPresented: $model.showsStopValidation,
                    onStop: model.stopImport)
            )
            .modifier(InvalidGameAlert(reason: $model.invalidReason))
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
                "Empo can't run this game.",
                isPresented: isPresented($model.launchFailure),
                presenting: model.launchFailure
            ) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.message)
            }
            .modifier(ImportAlerts(model: model))
            .alert(
                launcher.lastFailure?.title ?? "",
                isPresented: isPresented($launcher.lastFailure),
                presenting: launcher.lastFailure
            ) { failure in
                if let logURL = failure.logURL {
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
                }
                Button("OK") {}
            } message: { failure in
                if failure.logURL == nil {
                    Text("To find out why, turn on “Debug logs” in Settings, then play the game again.")
                }
            }
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
                Button("OK") {}
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
                Button("OK") {}
            } message: { alert in
                Text(alert.message)
            }
            .modifier(
                ImportReplaceAlert(
                    prompt: Binding(
                        get: { model.importPipeline.activeReplacePrompt },
                        set: { if $0 == nil { model.importPipeline.dismissReplacePrompt() } }
                    ),
                    onReplace: model.importPipeline.confirmReplace,
                    onCancel: model.importPipeline.cancelReplace
                )
            )
    }
}

private func isPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}
