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
    var library = GameLibrary.shared
    var settings = AppSettings.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var errorTitle: String = "Oops!"
    @State private var showErrorAlert = false
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

    private var showEmpty: Bool {
        library.games.isEmpty
    }

    private var filteredGames: [GameEntry] {
        let base = searchText.isEmpty ? library.games : library.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return sortGames(base)
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

    private var columns: [GridItem] {
        let count = verticalSizeClass == .compact ? 5 : 3
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
                        .offset(y: -30)
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
                ImportButton(
                    showEmpty: showEmpty,
                    showImporter: $showImporter,
                    splashDismissed: splashDismissed,
                    entranceDelay: entranceDelay,
                    headerHeight: headerHeight,
                    emptyStateHeight: emptyStateHeight,
                    emptyStateOffset: -30
                )
            }
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
            .alert("A game is paused", isPresented: $showPausedGameAlert) {
                Button("Cancel", role: .cancel) {
                    pendingGame = nil
                }
                Button("Quit and play") {
                    guard let game = pendingGame else { return }
                    pendingGame = nil
                    appState.returnToLibrary()
                    // `returnToLibrary` sets phase=nil synchronously, but
                    // the RGSS thread takes a moment to actually reach
                    // `mkxp_setEngineTerminated()` and clear its pathSet
                    // flag. If we call `selectGame` too early, the new
                    // pathSet we set there gets clobbered by the engine's
                    // later `s_pathSet = false` reset, and the next
                    // session hangs in `waitForGamePath` forever.
                    // Poll `mkxp_isEngineTerminated()` instead, which is
                    // flipped ON by the RGSS thread right before it
                    // enters its next waitForGamePath loop. We also
                    // give up after ~5s to avoid looping forever if the
                    // thread truly hung; the hang watchdog in
                    // AppState will surface that case separately.
                    Task { @MainActor in
                        let deadline = Date().addingTimeInterval(5)
                        while mkxp_isEngineTerminated() == 0 && Date() < deadline {
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                        appState.selectGame(game)
                        path.append(game)
                    }
                }
            } message: {
                if let paused = PauseManager.shared.pausedGame {
                    Text("\"\(paused.title)\" is still running. Quit it to play a different game?")
                }
            }
            .tint(nil)
            .navigationDestination(for: GameEntry.self) { game in
                GameLoadingView(game: game)
                    .navigationTransition(.zoom(sourceID: game.id, in: heroNamespace))
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


    private let headerHeight: CGFloat = 56
    private let searchBarHeight: CGFloat = 44

    private var libraryHeader: some View {
        HStack {
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
        .padding(.horizontal)
        .frame(height: headerHeight)
    }


    private var searchBar: some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search games", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.lg)
            .frame(height: searchBarHeight)
            .glassEffect(.regular.interactive(), in: .capsule)

            IconButton("arrow.up.arrow.down", style: .outline) {
                showSortSheet = true
            }
            .accessibilityLabel("Sort games")

            IconButton(
                settings.libraryDisplayMode == .grid ? "list.bullet" : "square.grid.2x2",
                style: .outline,
                contentTransition: .symbolEffect(.replace)
            ) {
                withAnimation(Motion.standard) {
                    settings.libraryDisplayMode = settings.libraryDisplayMode == .grid ? .list : .grid
                }
                DispatchQueue.main.async {
                    staggerTrigger = UUID()
                }
            }
            .accessibilityLabel(settings.libraryDisplayMode == .grid ? "Switch to list" : "Switch to grid")
        }
        .padding(.horizontal)
        .padding(.bottom, Spacing.xs)
        .tint(.primary)
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
        .animation(Motion.standard, value: filteredGames.map(\.id))
    }


    private func heroCard(for game: GameEntry) -> some View {
        let isPaused = PauseManager.shared.pausedGame?.id == game.id
        return heroCardContent(for: game, isPaused: isPaused, aspectRatio: 2.2)
    }

    private func heroListRow(for game: GameEntry) -> some View {
        let isPaused = PauseManager.shared.pausedGame?.id == game.id
        return heroCardContent(for: game, isPaused: isPaused, aspectRatio: 3.0)
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

    private func heroCardContent(for game: GameEntry, isPaused: Bool, aspectRatio: CGFloat) -> some View {
        Button { handleGameTap(game) } label: {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        importing: false,
                        shimmer: false
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("Continue playing")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(game.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .textShadow()
                            .lineLimit(1)
                    }
                    .padding(Spacing.xl)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isPaused ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .iconShadow()
                        .padding(Spacing.xl)
                }
                .clipShape(.rect(cornerRadius: Radius.lg))
                .cardShadow()
                .matchedTransitionSource(id: game.id, in: heroNamespace) { config in
                    config
                        .background(.black)
                        .clipShape(.rect(cornerRadius: Radius.lg))
                }
        }
        .buttonStyle(CardPressStyle())
        .environment(\.colorScheme, .dark)
        .gameContextMenu(game: game, appState: appState, onPlay: { handleGameTap(game) }, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
    }

    private var listInner: some View {
        LazyVStack(spacing: 0) {
            if let hero = recentlyPlayed {
                heroListRow(for: hero)
                    .transition(.cardAppear)

                librarySectionHeader
            }

            ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
                let isPaused = PauseManager.shared.pausedGame?.id == game.id
                Button {
                    switch game.status {
                    case .ready: handleGameTap(game)
                    case .invalid: showInvalidAlert = true
                    case .importing: break
                    }
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
                }
                .buttonStyle(.plain)
                .gameContextMenu(game: game, appState: appState, onPlay: { handleGameTap(game) }, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
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
        .animation(Motion.standard, value: filteredGames.map(\.id))
    }

    @ViewBuilder
    private var gridItems: some View {
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
                Button { showInvalidAlert = true } label: {
                    GameCard(game: game)
                }
                    .id("\(game.id)-invalid")
                    .buttonStyle(CardPressStyle())
                    .transition(.cardAppear)
                    .gameContextMenu(game: game, appState: appState, onPlay: { handleGameTap(game) }, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
                    .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

            case .ready:
                let isPaused = PauseManager.shared.pausedGame?.id == game.id
                Button { handleGameTap(game) } label: {
                    GameCard(game: game, isPaused: isPaused)
                        .matchedTransitionSource(id: game.id, in: heroNamespace) { config in
                            config
                                .background(.black)
                                .clipShape(.rect(cornerRadius: Radius.md))
                        }
                }
                    .id("\(game.id)-\(isPaused ? "paused" : "ready")")
                    .buttonStyle(CardPressStyle())
                    .transition(.cardAppear)
                .gameContextMenu(game: game, appState: appState, onPlay: { handleGameTap(game) }, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
                .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)
            }
        }
    }


    private func handleGameTap(_ game: GameEntry) {
        let pauseManager = PauseManager.shared
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

    private func sortGames(_ games: [GameEntry]) -> [GameEntry] {
        switch settings.librarySortOption {
        case .titleAZ:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleZA:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .recentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        case .leastRecentlyPlayed:
            return games.sorted { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
        case .largestSize:
            return games.sorted { (gameSizes[$0.id] ?? 0) > (gameSizes[$1.id] ?? 0) }
        case .smallestSize:
            return games.sorted { (gameSizes[$0.id] ?? 0) < (gameSizes[$1.id] ?? 0) }
        case .mostPlayed:
            return games.sorted { (playTime(for: $0) ?? 0) > (playTime(for: $1) ?? 0) }
        case .leastPlayed:
            return games.sorted { (playTime(for: $0) ?? 0) < (playTime(for: $1) ?? 0) }
        }
    }

    private func refreshGameSizes() {
        Task {
            var sizes: [String: Int64] = [:]
            for game in library.games {
                sizes[game.id] = await GameMetadata.diskSize(for: URL(fileURLWithPath: game.path))
            }
            gameSizes = sizes
        }
    }

    private func playTime(for game: GameEntry) -> TimeInterval? {
        GameMetadata.load(for: game.id).totalPlayTime
    }

    private var sortSheet: some View {
        NavigationStack {
            List {
                ForEach(LibrarySortOption.allCases, id: \.self) { option in
                    Button {
                        withAnimation(Motion.standard) {
                            settings.librarySortOption = option
                        }
                        showSortSheet = false
                    } label: {
                        HStack(spacing: Spacing.lg) {
                            Image(systemName: option.icon)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(option.label)
                            Spacer()
                            if settings.librarySortOption == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.brand)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Sort by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSortSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .tint(.brand)
    }
}
