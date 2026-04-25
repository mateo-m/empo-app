import SwiftUI

private struct EmptyStateHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct GameLibraryView: View {
    var appState: AppState
    var heroNamespace: Namespace.ID
    var splashDismissed: Bool = true
    @Environment(\.gameLibrary) private var library
    @Environment(\.appSettings) private var settings
    @Environment(\.pauseManager) private var pauseManager
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    // TODO(localization): once the app has a strings catalog these
    // copy fallbacks should move into it alongside the other
    // user-facing text. Keep the literals here for now so the
    // existing string-search audit still points at a single spot.
    @State private var errorTitle: String = "Oops!"
    @State private var showErrorAlert = false
    @State private var showCancelValidationAlert = false
    @State private var gameToDelete: GameEntry?
    @State private var showDeleteConfirm = false
    @State private var showInvalidAlert = false
    @State private var path = NavigationPath()
    @State private var searchText = ""
    @State private var gameForSettings: GameEntry?
    @State private var gameForInfo: GameEntry?
    @State private var pendingGame: GameEntry?
    @State private var showPausedGameAlert = false
    @State private var staggerTrigger = UUID()
    @State private var entranceDelay: TimeInterval = 0.15
    @State private var emptyStateHeight: CGFloat = 0
    @State private var showSortSheet = false
    @State private var gameSizes: [String: Int64] = [:]
    @State private var sizesTask: Task<Void, Never>?
    /// Per-game record of which visual source triggered the most recent
    /// navigation into the player. Drives `.navigationTransition(.zoom)`
    /// so the exit animation lands on the same spot the user tapped.
    @State private var tappedSource: [String: GameTapSource] = [:]

    // Multi-select state.
    //
    // Selection mode is entered via the "Select Multiple" item in
    // the per-game context menu (long-press -> menu -> Select).
    // Going through the existing context menu sidesteps the gesture
    // conflict that would arise if a raw long-press handler tried
    // to coexist with the system long-press that opens the context
    // menu itself. Once in selection mode the tap action on a card
    // toggles its membership in `selectedIDs`; tapping `Done` (in
    // the library header) or hitting the bulk-delete confirmation
    // exits.
    @State private var selectionMode: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBulkDeleteConfirm: Bool = false

    // Derived filter/sort pipeline. A previous attempt cached this in
    // @State and re-derived via .onChange, but passing library.games
    // through a ViewModifier broke the Observation dependency so stale
    // entries stuck around after reload (an imported game stayed in
    // the progress state forever). Keeping it computed means it
    // tracks library.games directly. Filter + sort on 10s of entries
    // is cheap; .map(\.id) in `.animation(value:)` was the actual
    // hot-loop offender and was dropped.
    private var filteredGames: [GameEntry] {
        let base = searchText.isEmpty
            ? library.games
            : library.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return GameSorting.sort(base, option: settings.librarySortOption, sizes: gameSizes)
    }

    /// Synthetic cards for pre-flight validations, pinned to the top
    /// of the grid/list. These only render when the library is
    /// already populated - the empty-state flow keeps validation
    /// feedback on the Import button so the empty state doesn't
    /// bounce in and out on invalid imports.
    private var pendingValidationEntries: [GameEntry] {
        guard !library.games.isEmpty else { return [] }
        return library.pendingImports.values
            .sorted { $0.id < $1.id }
            .map(\.syntheticEntry)
    }

    private var showEmpty: Bool {
        library.games.isEmpty
    }

    private var recentlyPlayed: GameEntry? {
        guard settings.showContinuePlaying else { return nil }
        guard searchText.isEmpty else { return nil }
        let readyGames = library.games.filter { $0.status == .ready }
        guard readyGames.count > 1 else { return nil }  // no hero if only 1 game

        return readyGames
            .filter { $0.lastPlayed != nil }
            .max(by: { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) })
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // Cached grid columns, rebuilt only when the size class changes.
    // Previously this was a computed property that allocated a fresh
    // array on every body tick.
    @State private var columns: [GridItem] = Self.makeColumns(compact: false)

    private static func makeColumns(compact: Bool) -> [GridItem] {
        let count = compact ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: Spacing.lg), count: count)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                if !showEmpty {
                    gameContent
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if showEmpty {
                    emptyStateContent
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(key: EmptyStateHeightKey.self, value: geo.size.height)
                            }
                        }
                        .offset(y: -AppSize.emptyStateOffset)
                        .transition(.emptyState)
                }
            }
            .onPreferenceChange(EmptyStateHeightKey.self) { emptyStateHeight = $0 }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: Spacing.md) {
                    libraryHeader
                    if !showEmpty {
                        searchBar
                    }
                }
                .background {
                    Rectangle()
                        .fill(Color(.systemBackground))
                        .padding(.bottom, -30)
                        .mask {
                            VStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(
                                    colors: [.black, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 30)
                            }
                        }
                        .ignoresSafeArea(edges: .top)
                }
            }
            .background {
                Color(.systemBackground)
                    .ignoresSafeArea()
            }
            .animation(Motion.standard, value: showEmpty)
            .onChange(of: splashDismissed) { _, dismissed in
                if dismissed {
                    staggerTrigger = UUID()
                    // Clear entrance delay after first mount so subsequent
                    // animations (view mode switch, new imports) play instantly.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        entranceDelay = 0
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if !selectionMode {
                    ImportButton(
                        showEmpty: showEmpty,
                        showImporter: $showImporter,
                        splashDismissed: splashDismissed,
                        entranceDelay: entranceDelay,
                        headerHeight: headerHeight,
                        emptyStateHeight: emptyStateHeight,
                        emptyStateOffset: -AppSize.emptyStateOffset,
                        // Only the empty-state Import button shows a
                        // validating label. When the library already has
                        // games, pre-flight feedback lives on the grid/list
                        // cards instead (see pendingValidationEntries).
                        isValidating: showEmpty && !library.pendingImports.isEmpty,
                        onRequestCancelValidation: { showCancelValidationAlert = true }
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selectionMode {
                    bottomSelectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .modifier(BulkDeleteAlert(
                isPresented: $showBulkDeleteConfirm,
                count: selectedIDs.count,
                onConfirm: confirmBulkDelete
            ))
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showImporter) {
                DocumentPickerView { urls in
                    importGames(from: urls)
                }
            }
            .sheet(item: $gameForSettings) { game in
                GameSettingsView(game: game)
            }
            .sheet(item: $gameForInfo) { game in
                GameInfoView(game: game)
            }
            .sheet(isPresented: $showSortSheet) {
                sortSheet
            }
            .alert(errorTitle, isPresented: $showErrorAlert) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
            .alert("Delete Game?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let game = gameToDelete {
                        library.deleteGame(game) { error in
                            errorMessage = error
                            showErrorAlert = true
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                if let game = gameToDelete {
                    Text("This will remove all files for \"\(game.title)\". You can always re-import it later.")
                }
            }
            .alert("Invalid Game", isPresented: $showInvalidAlert) {
                Button("OK") {}
            } message: {
                Text("This game couldn't be loaded properly. You can delete it and try importing again.")
            }
            .alert("Cancel import?", isPresented: $showCancelValidationAlert) {
                Button("Keep importing", role: .cancel) {}
                Button("Cancel import", role: .destructive) {
                    for id in library.pendingImports.keys {
                        library.cancelPendingImport(id)
                    }
                }
            } message: {
                Text("The game is still being validated. Cancelling will stop the import.")
            }
            .alert("A game is paused", isPresented: $showPausedGameAlert) {
                Button("Cancel", role: .cancel) {
                    pendingGame = nil
                }
                Button("Quit and play") {
                    guard let game = pendingGame else { return }
                    pendingGame = nil
                    appState.returnToLibrary()
                    // selectGame now waits internally for the engine to
                    // finish terminating before handing it the new path,
                    // so this site no longer needs its own polling loop.
                    appState.selectGame(game)
                    path.append(game)
                }
            } message: {
                if let paused = pauseManager.pausedGame {
                    Text("\"\(paused.title)\" is still running. Quit it to play a different game?")
                }
            }
            .tint(nil)
            .navigationDestination(for: GameEntry.self) { game in
                // The zoom destination targets whichever visible source
                // the user tapped (hero card vs grid/list item). When
                // the source is unknown (e.g. external deep link), fall back
                // to the grid/list item source id since that's the one
                // always visible in the library.
                let source = tappedSource[game.id] ?? .item
                GameLoadingView(game: game)
                    .navigationTransition(.zoom(sourceID: source.transitionID(for: game.id),
                                                in: heroNamespace))
            }
            .onChange(of: appState.phase) { _, newPhase in
                if newPhase == nil && !path.isEmpty {
                    path = NavigationPath()
                }
                if newPhase == nil {
                    refreshGameSizes()
                }
            }
            .onChange(of: settings.librarySortOption) { _, newSort in
                if newSort == .largestSize || newSort == .smallestSize {
                    refreshGameSizes()
                }
            }
            .onChange(of: verticalSizeClass, initial: true) { _, newClass in
                columns = Self.makeColumns(compact: newClass == .compact)
            }
            .task {
                refreshGameSizes()
            }
        }
    }


    private var emptyStateContent: some View {
        EmptyStateView(
            icon: "gamecontroller",
            title: "No Games Yet",
            subtitle: "Add your favorite RPG Maker\ngames to get started!",
            revealed: splashDismissed,
            initialDelay: entranceDelay
        )
    }


    private let headerHeight: CGFloat = AppSize.libraryHeader

    private var libraryHeader: some View {
        HStack {
            if selectionMode {
                Button("Done") { exitSelectionMode() }
                    .font(.body.weight(.semibold))
                    .tint(.brand)
                Spacer()
                Text(selectedIDs.isEmpty
                     ? "Select Games"
                     : "\(selectedIDs.count) Selected")
                    .font(.headline)
                Spacer()
                // Symmetry placeholder so the title stays centered.
                Color.clear.frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                    .accessibilityHidden(true)
            } else {
                IconButton("gearshape", style: .outline) { showSettings = true }
                    .accessibilityLabel("Settings")
                Spacer()
                Text("Library")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                Color.clear.frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal)
        .frame(height: headerHeight)
        .animation(Motion.standard, value: selectionMode)
    }


    private var searchBar: some View {
        LibrarySearchBar(
            searchText: $searchText,
            showSortSheet: $showSortSheet,
            onDisplayModeToggle: {
                withAnimation(Motion.standard) {
                    settings.libraryDisplayMode = settings.libraryDisplayMode == .grid ? .list : .grid
                }
                Task { @MainActor in
                    staggerTrigger = UUID()
                }
            }
        )
    }


    private var gameContent: some View {
        ScrollView {
            if settings.libraryDisplayMode == .grid {
                gridInner
                    .transition(.viewModeSwitch)
            } else {
                listInner
                    .transition(.viewModeSwitch)
            }
        }
        .overlay {
            if !searchText.isEmpty && filteredGames.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var gridInner: some View {
        VStack(spacing: Spacing.lg) {
            if let hero = recentlyPlayed {
                heroCard(for: hero)
                    .transition(.cardAppear)

                librarySectionHeader
            }

            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                gridItems
            }
        }
        .padding(.horizontal)
        .padding(.top, Spacing.lg)
        .padding(.bottom)
        .animation(Motion.standard, value: filteredGames)
    }


    private func heroCard(for game: GameEntry) -> some View {
        let isPaused = pauseManager.pausedGame?.id == game.id
        // In landscape the narrower vertical space means a 2.2:1 ratio
        // hero card eats most of the screen and pushes the grid below
        // the fold. Widen it in compact-height so the card stays
        // visible but the grid also gets breathing room.
        let ratio: CGFloat = verticalSizeClass == .compact ? 4.5 : 2.2
        return GameHeroCard(
            game: game,
            isPaused: isPaused,
            aspectRatio: ratio,
            heroNamespace: heroNamespace,
            appState: appState,
            onTap: { handleGameTap(game, from: .hero) },
            gameToDelete: $gameToDelete,
            showDeleteConfirm: $showDeleteConfirm,
            gameForSettings: $gameForSettings,
            gameForInfo: $gameForInfo
        )
    }

    private func heroListRow(for game: GameEntry) -> some View {
        let isPaused = pauseManager.pausedGame?.id == game.id
        let ratio: CGFloat = verticalSizeClass == .compact ? 5.0 : 3.0
        return GameHeroCard(
            game: game,
            isPaused: isPaused,
            aspectRatio: ratio,
            heroNamespace: heroNamespace,
            appState: appState,
            onTap: { handleGameTap(game, from: .hero) },
            gameToDelete: $gameToDelete,
            showDeleteConfirm: $showDeleteConfirm,
            gameForSettings: $gameForSettings,
            gameForInfo: $gameForInfo
        )
    }

    private var librarySectionHeader: some View {
        HStack {
            Text("All games")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, Spacing.sm)
    }

    private var listInner: some View {
        LazyVStack(spacing: 0) {
            if let hero = recentlyPlayed {
                heroListRow(for: hero)
                    .transition(.cardAppear)

                librarySectionHeader
            }

            ForEach(pendingValidationEntries, id: \.id) { pending in
                GameListRow(
                    game: pending,
                    onStopImport: { showCancelValidationAlert = true }
                )
                .id("\(pending.id)-pending")
                .transition(.cardAppear)
            }

            ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
                let isPaused = pauseManager.pausedGame?.id == game.id
                Button {
                    handleCardTap(for: game)
                } label: {
                    GameListRow(
                        game: game,
                        isPaused: isPaused,
                        heroNamespace: game.status == .ready ? heroNamespace : nil,
                        onStopImport: game.status.phase == .importing ? {
                            gameToDelete = game
                            showDeleteConfirm = true
                        } : nil
                    )
                    // Anchor on .topLeading so the badge floats over
                    // the artwork's top-left corner instead of fighting
                    // with the trailing GameStatusIndicator (which lives
                    // on the row's trailing edge). Slight inset matches
                    // the artwork's padding so the badge sits inside
                    // the artwork rectangle.
                    .overlay(alignment: .topLeading) {
                        if selectionMode && game.status == .ready {
                            selectionBadge(for: game.id)
                                .padding(.leading, Spacing.xs)
                                .padding(.top, Spacing.xs)
                        }
                    }
                }
                .buttonStyle(ListRowPressStyle())
                .gameContextMenu(
                    game: game,
                    appState: appState,
                    onPlay: { handleGameTap(game, from: .item) },
                    gameToDelete: $gameToDelete,
                    showDeleteConfirm: $showDeleteConfirm,
                    gameForSettings: $gameForSettings,
                    gameForInfo: $gameForInfo,
                    onEnterMultiSelect: { enterSelectionMode(seedingWith: game.id) }
                )
                .transition(.cardAppear)
                .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

                if index < filteredGames.count - 1 {
                    Divider()
                        .padding(.leading, AppSize.listArtwork + Spacing.lg * 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, Spacing.lg)
        .animation(Motion.standard, value: filteredGames)
        .animation(Motion.standard, value: pendingValidationEntries)
    }

    @ViewBuilder
    private var gridItems: some View {
        ForEach(pendingValidationEntries, id: \.id) { pending in
            GameCard(
                game: pending,
                onStopImport: { showCancelValidationAlert = true }
            )
            .id("\(pending.id)-pending")
            .transition(.cardAppear)
        }

        ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
            switch game.status {
            case .importing:
                GameCard(game: game, onStopImport: {
                    gameToDelete = game
                    showDeleteConfirm = true
                })
                    .id("\(game.id)-importing")
                    .transition(.cardAppear)
                    .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

            case .invalid:
                Button { handleCardTap(for: game) } label: {
                    GameCard(game: game)
                }
                    .id("\(game.id)-invalid")
                    .buttonStyle(CardPressStyle())
                    .transition(.cardAppear)
                    .gameContextMenu(
                        game: game,
                        appState: appState,
                        onPlay: { handleGameTap(game, from: .item) },
                        gameToDelete: $gameToDelete,
                        showDeleteConfirm: $showDeleteConfirm,
                        gameForSettings: $gameForSettings,
                        gameForInfo: $gameForInfo
                        // No multi-select for .invalid - their state isn't safely
                        // bulk-deletable through the same path as ready games.
                    )
                    .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

            case .ready:
                let isPaused = pauseManager.pausedGame?.id == game.id
                Button { handleCardTap(for: game) } label: {
                    GameCard(game: game, isPaused: isPaused)
                        .matchedTransitionSource(id: GameTapSource.item.transitionID(for: game.id),
                                                 in: heroNamespace) { config in
                            config
                                .background(.black)
                                .clipShape(.rect(cornerRadius: Radius.md))
                        }
                        .overlay(alignment: .topTrailing) {
                            if selectionMode {
                                selectionBadge(for: game.id)
                                    .padding(Spacing.sm)
                            }
                        }
                }
                    // NOTE: no .id("...-\(isPaused)") here on purpose.
                    // Forcing a remount on pause toggle destroys the
                    // matchedTransitionSource mid-animation, which
                    // makes the exit hero zoom snap to a fallback
                    // frame at its end. GameCard already animates its
                    // own pause overlay via GameStatusIndicator's
                    // internal .animation(Motion.gentle, value: …),
                    // so no remount is needed.
                    .buttonStyle(CardPressStyle())
                    .transition(.cardAppear)
                .gameContextMenu(
                    game: game,
                    appState: appState,
                    onPlay: { handleGameTap(game, from: .item) },
                    gameToDelete: $gameToDelete,
                    showDeleteConfirm: $showDeleteConfirm,
                    gameForSettings: $gameForSettings,
                    gameForInfo: $gameForInfo,
                    onEnterMultiSelect: { enterSelectionMode(seedingWith: game.id) }
                )
                .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)
            }
        }
    }


    /// Tap entrypoint for grid cards / list rows. Branches on
    /// selection mode: when active, taps toggle membership in
    /// `selectedIDs` (and only on .ready games - importing /
    /// invalid cards aren't legal multi-select targets); otherwise
    /// dispatches to the existing per-status flow.
    private func handleCardTap(for game: GameEntry) {
        if selectionMode {
            guard game.status == .ready else { return }
            toggleSelection(game.id)
            return
        }
        switch game.status {
        case .ready:     handleGameTap(game, from: .item)
        case .invalid:   showInvalidAlert = true
        case .importing: break
        }
    }

    private func enterSelectionMode(seedingWith gameId: String) {
        Haptics.impact()
        withAnimation(Motion.standard) {
            selectionMode = true
            selectedIDs = [gameId]
        }
    }

    private func exitSelectionMode() {
        withAnimation(Motion.standard) {
            selectionMode = false
            selectedIDs = []
        }
    }

    private func toggleSelection(_ gameId: String) {
        withAnimation(Motion.gentle) {
            if selectedIDs.contains(gameId) {
                selectedIDs.remove(gameId)
            } else {
                selectedIDs.insert(gameId)
            }
        }
    }

    private func confirmBulkDelete() {
        // Capture the snapshot so the loop survives state mutation
        // from `library.deleteGame`'s reload chain.
        let ids = selectedIDs
        let games = library.games.filter { ids.contains($0.id) }
        for game in games {
            library.deleteGame(game) { error in
                errorTitle = "Couldn't delete \"\(game.title)\""
                errorMessage = error
                showErrorAlert = true
            }
        }
        exitSelectionMode()
    }

    /// Circular checkmark glyph rendered on each card/row while in
    /// selection mode. Filled brand circle when selected, hollow
    /// white-stroked circle otherwise. Sized to read at both grid
    /// (3-up portrait, larger cards) and list (48pt artwork) scales.
    @ViewBuilder
    private func selectionBadge(for gameId: String) -> some View {
        let selected = selectedIDs.contains(gameId)
        ZStack {
            Circle()
                .fill(selected ? Color.brand : Color.black.opacity(0.4))
                .frame(width: 24, height: 24)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .accessibilityLabel(selected ? "Selected" : "Not selected")
    }

    /// Bottom action bar shown when in selection mode. Hosts
    /// the bulk-delete CTA. Pinned via `.safeAreaInset(.bottom)`
    /// so it overlays the scroll content without affecting the
    /// scroll view's own bottom inset more than its own height.
    private var bottomSelectionBar: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                showBulkDeleteConfirm = true
            } label: {
                Label("Delete (\(selectedIDs.count))", systemImage: "trash")
                    .font(.body.weight(.semibold))
            }
            .disabled(selectedIDs.isEmpty)
            .tint(.red)
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.regularMaterial)
    }

    private func handleGameTap(_ game: GameEntry, from source: GameTapSource = .item) {
        tappedSource[game.id] = source
        if pauseManager.pausedGame?.id == game.id {
            appState.resumePausedGame()
            path.append(game)
        } else if pauseManager.pausedGame != nil {
            pendingGame = game
            showPausedGameAlert = true
        } else {
            appState.selectGame(game)
            path.append(game)
        }
    }


    private func importGames(from urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            let archiveName = url.deletingPathExtension().lastPathComponent

            library.importGame(from: url) { error in
                if accessing { url.stopAccessingSecurityScopedResource() }
                if let error = error {
                    errorTitle = "Couldn't import \"\(archiveName)\""
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                } else {
                    Haptics.impact()
                }
            }
        }
    }

    private func refreshGameSizes() {
        sizesTask?.cancel()
        sizesTask = Task {
            var sizes: [String: Int64] = [:]
            for game in library.games {
                guard !Task.isCancelled else { return }
                sizes[game.id] = await GameMetadata.diskSize(for: URL(fileURLWithPath: game.path))
            }
            guard !Task.isCancelled else { return }
            gameSizes = sizes
        }
    }

    private var sortSheet: some View {
        LibrarySortSheet(isPresented: $showSortSheet)
    }
}


/// Alert wrapper for the bulk-delete confirmation. Inlining the
/// alert directly into `GameLibraryView.body` pushes the body
/// builder over SwiftUI's type-checker budget (every additional
/// modifier on the same `.NavigationStack { ZStack { ... } ... }`
/// chain widens the inferred type by one envelope, and the body
/// is already thick with sheets / alerts / overlays). Extracting
/// to a ViewModifier keeps `body` lean.
private struct BulkDeleteAlert: ViewModifier {
    @Binding var isPresented: Bool
    let count: Int
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete \(count) Games?", isPresented: $isPresented) {
            Button("Delete", role: .destructive) {
                onConfirm()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all files for the selected games. You can always re-import them later.")
        }
    }
}


