import SwiftUI

private struct EmptyStateHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct GameLibraryView: View {
    var heroNamespace: Namespace.ID
    var splashDismissed: Bool = true
    @Environment(\.appState) private var appState
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
    @State private var importPipeline = ImportPipeline()
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
    // is cheap; animating on full `[GameEntry]` arrays (and their
    // associated values like import progress) was the hot-loop
    // offender. Lightweight id/phase keys replace those triggers.
    private var filteredGames: [GameEntry] {
        library.displayedCatalog(
            search: searchText,
            sort: settings.librarySortOption,
            sizes: gameSizes
        )
    }

    private var catalogAnimationKey: [String] {
        filteredGames.map { "\($0.id):\($0.status.phase)" }
    }

    /// Synthetic cards for pre-flight validations, pinned to the top
    /// of the grid/list. These only render when the library is
    /// already populated - the empty-state flow keeps validation
    /// feedback on the Import button so the empty state doesn't
    /// bounce in and out on invalid imports.
    private var pendingValidationEntries: [GameEntry] {
        library.pendingValidationCatalog()
    }

    private var showEmpty: Bool {
        library.games.isEmpty
    }

    private var recentlyPlayed: GameEntry? {
        library.recentlyPlayedCandidate(
            showContinuePlaying: settings.showContinuePlaying,
            searchText: searchText
        )
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
            navigationContent
        }
    }

    private var navigationContent: some View {
        libraryPresentedContent
            .tint(nil)
            .navigationDestination(for: GameEntry.self) { game in
                // The zoom destination targets whichever visible source
                // the user tapped (hero card vs grid/list item). When
                // the source is unknown (e.g. external deep link), fall back
                // to the grid/list item source id since that's the one
                // always visible in the library.
                let source = tappedSource[game.id] ?? .item
                GameLoadingView(game: game)
                    .navigationTransition(
                        .zoom(
                            sourceID: source.transitionID(for: game.id),
                            in: heroNamespace))
            }
            .onChange(of: appState.phase) { _, newPhase in
                handleAppPhaseChange(newPhase)
            }
            .onChange(of: settings.librarySortOption) { _, newSort in
                handleSortOptionChange(newSort)
            }
            .onChange(of: verticalSizeClass, initial: true) { _, newClass in
                columns = Self.makeColumns(compact: newClass == .compact)
            }
            .task(id: ObjectIdentifier(library)) {
                importPipeline.configure(library: library)
            }
            .task {
                refreshGameSizes()
            }
    }

    private var libraryPresentedContent: some View {
        libraryScene
            .modifier(
                BulkDeleteAlert(
                    isPresented: $showBulkDeleteConfirm,
                    count: selectedIDs.count,
                    onConfirm: confirmBulkDelete
                )
            )
            .modifier(
                LibrarySheetPresentation(
                    showSettings: $showSettings,
                    showImporter: $showImporter,
                    gameForSettings: $gameForSettings,
                    gameForInfo: $gameForInfo,
                    showSortSheet: $showSortSheet,
                    importRootPrompt: importRootPromptBinding,
                    onImportPicked: importPipeline.enqueue,
                    onCancelImportChoice: importPipeline.cancelChoice,
                    onConfirmImportChoice: importPipeline.confirmChoice
                )
            )
            .modifier(
                LibraryAlertPresentation(
                    title: errorTitle,
                    errorMessage: errorMessage,
                    showErrorAlert: $showErrorAlert,
                    gameToDelete: $gameToDelete,
                    showDeleteConfirm: $showDeleteConfirm,
                    showInvalidAlert: $showInvalidAlert,
                    showCancelValidationAlert: $showCancelValidationAlert,
                    showPausedGameAlert: $showPausedGameAlert,
                    importPipelineAlert: importPipelineAlertBinding,
                    pausedGame: pauseManager.pausedGame,
                    onDeleteGame: deleteSelectedGame,
                    onDismissImportPipelineAlert: importPipeline.dismissAlert,
                    onCancelValidation: importPipeline.cancelValidation,
                    onDismissPausedGameAlert: { pendingGame = nil }
                )
            )
            .toolbarVisibility(.hidden, for: .navigationBar)
    }

    private var libraryScene: some View {
        libraryContentLayer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { emptyStateOverlay }
            .onPreferenceChange(EmptyStateHeightKey.self) { emptyStateHeight = $0 }
            .safeAreaInset(edge: .top, spacing: 0) { headerInset }
            .background { libraryBackground }
            .animation(Motion.standard, value: showEmpty)
            .onChange(of: splashDismissed) { _, dismissed in
                handleSplashDismissedChange(dismissed)
            }
            .overlay(alignment: .topTrailing) { importButtonOverlay }
            .overlay(alignment: .bottom) { bulkDeleteOverlay }
            .safeAreaInset(edge: .bottom, spacing: 0) { updateBannerInset }
            .animation(Motion.bouncy, value: showsUpdateBanner)
    }

    private var libraryContentLayer: some View {
        ZStack {
            if !showEmpty {
                gameContent
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
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

    private var headerInset: some View {
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

    private var libraryBackground: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }

    private var showsUpdateBanner: Bool {
        guard !selectionMode, !appState.updateBannerDismissed else { return false }
        guard case .available = appState.updateStatus else { return false }
        return true
    }

    @ViewBuilder
    private var updateBannerInset: some View {
        if showsUpdateBanner {
            libraryUpdateBanner
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing._2xl)
                .transition(.move(edge: .bottom).combined(with: .fadeBlur))
        }
    }

    @ViewBuilder
    private var importButtonOverlay: some View {
        if !selectionMode {
            ImportButton(
                showEmpty: showEmpty,
                showImporter: $showImporter,
                splashDismissed: splashDismissed,
                entranceDelay: entranceDelay,
                headerHeight: headerHeight,
                emptyStateHeight: emptyStateHeight,
                emptyStateOffset: -AppSize.emptyStateOffset,
                // The empty-state button shows full status text.
                // In the populated library the button is still
                // collapsed, but using the same phase lets it
                // surface a spinner during archive/root
                // inspection before any progress card exists.
                phase: importPipeline.importButtonPhase,
                onRequestCancelValidation: { showCancelValidationAlert = true }
            )
        }
    }

    @ViewBuilder
    private var bulkDeleteOverlay: some View {
        if selectionMode && !selectedIDs.isEmpty {
            bulkDeleteButton
                .padding(.bottom, Spacing._2xl)
                // Blur + scale + opacity rather than slide-up.
                // Reuses `.cardAppear` (the same transition the
                // grid/list cards use on enter/exit) so the
                // delete button feels like it belongs to the
                // same animation family as the rest of the
                // library content.
                .transition(.cardAppear)
        }
    }

    private var libraryUpdateBanner: some View {
        UpdateStatusIndicator(
            status: appState.updateStatus,
            onTapRetry: {
                await appState.checkForUpdatesNow()
            },
            canDismiss: true,
            onDismiss: {
                withAnimation(Motion.gentle) {
                    appState.updateBannerDismissed = true
                }
            }
        )
    }

    private var emptyStateContent: some View {
        EmptyStateView(
            icon: Image(.empoMark),
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
                // Symmetry placeholder on the left so the title
                // stays optically centered when "Done" sits trailing.
                Color.clear.frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                    .accessibilityHidden(true)
                Spacer()
                Text(
                    selectedIDs.isEmpty
                        ? "Select Games"
                        : "\(selectedIDs.count) Selected"
                )
                .font(.headline)
                Spacer()
                Button("Done") { exitSelectionMode() }
                    .font(.body.weight(.semibold))
                    .tint(.brand)
            } else {
                IconButton("gearshape", style: .outline) { showSettings = true }
                    .accessibilityLabel("Settings")
                Spacer()
                Text("Library")
                    .font(.title)
                    .fontWeight(.bold)
                Spacer()
                // Right-side placeholder. Keeping the symmetry slot
                // empty (rather than putting the Select-multiple
                // icon here) avoids colliding with the floating
                // ImportButton which sits at the same screen
                // position. The Select-multiple entry point lives
                // in LibrarySearchBar instead.
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
        .animation(Motion.standard, value: catalogAnimationKey)
        .animation(Motion.standard, value: pendingValidationEntries.map(\.id))
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
                .gameContextMenu(
                    game: pending,
                    appState: appState,
                    onPlay: {},
                    onCancelImport: { showCancelValidationAlert = true },
                    gameToDelete: $gameToDelete,
                    showDeleteConfirm: $showDeleteConfirm,
                    gameForSettings: $gameForSettings,
                    gameForInfo: $gameForInfo
                )
                .id("\(pending.id)-pending")
                .transition(.cardAppear)
            }

            ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
                listRow(for: game, index: index)

                if index < filteredGames.count - 1 {
                    Divider()
                        .padding(.leading, AppSize.listArtwork + Spacing.lg * 2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, Spacing.lg)
        .animation(Motion.standard, value: catalogAnimationKey)
        .animation(Motion.standard, value: pendingValidationEntries.map(\.id))
    }

    @ViewBuilder
    private var gridItems: some View {
        ForEach(pendingValidationEntries, id: \.id) { pending in
            GameCard(
                game: pending,
                onStopImport: { showCancelValidationAlert = true }
            )
            .cardShadow()
            .gameContextMenu(
                game: pending,
                appState: appState,
                onPlay: {},
                onCancelImport: { showCancelValidationAlert = true },
                gameToDelete: $gameToDelete,
                showDeleteConfirm: $showDeleteConfirm,
                gameForSettings: $gameForSettings,
                gameForInfo: $gameForInfo
            )
            .id("\(pending.id)-pending")
            .transition(.cardAppear)
        }

        ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
            gridItem(for: game, index: index)
        }
    }

    private func listRow(for game: GameEntry, index: Int) -> some View {
        let isPaused = pauseManager.pausedGame?.id == game.id
        return Button {
            handleCardTap(for: game)
        } label: {
            GameListRow(
                game: game,
                isPaused: isPaused,
                heroNamespace: game.status == .ready ? heroNamespace : nil,
                onStopImport: game.status.phase == .importing
                    ? {
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
            onCancelImport: game.isImporting
                ? {
                    gameToDelete = game
                    showDeleteConfirm = true
                } : nil,
            onSelect: selectionMode ? nil : { enterSelectionMode(seedingWith: game.id) },
            gameToDelete: $gameToDelete,
            showDeleteConfirm: $showDeleteConfirm,
            gameForSettings: $gameForSettings,
            gameForInfo: $gameForInfo
        )
        .transition(.cardAppear)
        .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)
    }

    @ViewBuilder
    private func gridItem(for game: GameEntry, index: Int) -> some View {
        switch game.status {
        case .importing:
            GameCard(
                game: game,
                onStopImport: {
                    gameToDelete = game
                    showDeleteConfirm = true
                }
            )
            .cardShadow()
            .gameContextMenu(
                game: game,
                appState: appState,
                onPlay: {},
                onCancelImport: {
                    gameToDelete = game
                    showDeleteConfirm = true
                },
                gameToDelete: $gameToDelete,
                showDeleteConfirm: $showDeleteConfirm,
                gameForSettings: $gameForSettings,
                gameForInfo: $gameForInfo
            )
            .id("\(game.id)-importing")
            .transition(.cardAppear)
            .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

        case .invalid:
            Button {
                handleCardTap(for: game)
            } label: {
                GameCard(game: game)
                    .cardShadow()
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
            )
            .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

        case .ready:
            readyGridItem(for: game, index: index)
        }
    }

    private func readyGridItem(for game: GameEntry, index: Int) -> some View {
        let isPaused = pauseManager.pausedGame?.id == game.id
        return Button {
            handleCardTap(for: game)
        } label: {
            GameCard(game: game, isPaused: isPaused)
                .matchedTransitionSource(
                    id: GameTapSource.item.transitionID(for: game.id),
                    in: heroNamespace
                ) { config in
                    config
                        .background(.black)
                        .clipShape(.rect(cornerRadius: Radius.md))
                }
                .cardShadow()
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
            onSelect: selectionMode ? nil : { enterSelectionMode(seedingWith: game.id) },
            gameToDelete: $gameToDelete,
            showDeleteConfirm: $showDeleteConfirm,
            gameForSettings: $gameForSettings,
            gameForInfo: $gameForInfo
        )
        .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)
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
        case .ready: handleGameTap(game, from: .item)
        case .invalid: showInvalidAlert = true
        case .importing: break
        }
    }

    /// Enter selection mode. When `gameId` is non-nil the game is
    /// pre-selected (used when entering from a per-card affordance);
    /// when nil the user starts with an empty selection (used by
    /// the library-header Select icon).
    private func enterSelectionMode(seedingWith gameId: String? = nil) {
        Haptics.impact()
        withAnimation(Motion.standard) {
            selectionMode = true
            selectedIDs = gameId.map { [$0] } ?? []
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

    /// Floating bulk-delete CTA shown over the library content
    /// when in selection mode AND at least one game is selected.
    /// Routed through the design system's `.primary` glass-capsule
    /// style with a red tint so it reads as the same family of
    /// action as the rest of the app's primary buttons - not an
    /// iOS toolbar bar. Visibility is gated at the call-site so
    /// the button physically appears/disappears with the selection
    /// (no greyed-out empty state taking up screen real estate).
    private var bulkDeleteButton: some View {
        Button(role: .destructive) {
            showBulkDeleteConfirm = true
        } label: {
            Label("Delete (\(selectedIDs.count))", systemImage: "trash")
        }
        .buttonStyle(.primary(tint: .red))
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

    private func refreshGameSizes() {
        sizesTask?.cancel()
        sizesTask = Task {
            var sizes: [String: Int64] = [:]
            for game in library.games {
                guard !Task.isCancelled else { return }
                guard let container = game.container else { continue }
                // Whole container size (Game/ + EmpoState/ + Logs/
                // + Metadata/) - dominated by Game/ in practice.
                sizes[game.id] = await GameMetadata.diskSize(for: container.url)
            }
            guard !Task.isCancelled else { return }
            gameSizes = sizes
        }
    }

    private func handleSplashDismissedChange(_ dismissed: Bool) {
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

    private func handleAppPhaseChange(_ newPhase: GamePhase?) {
        if newPhase == nil && !path.isEmpty {
            path = NavigationPath()
        }
        if newPhase == nil {
            refreshGameSizes()
        }
    }

    private func handleSortOptionChange(_ newSort: LibrarySortOption) {
        if newSort == .largestSize || newSort == .smallestSize {
            refreshGameSizes()
        }
    }

    private func deleteSelectedGame() {
        guard let game = gameToDelete else { return }
        library.deleteGame(game) { error in
            errorMessage = error
            showErrorAlert = true
        }
    }

    private var importRootPromptBinding: Binding<ImportRootPrompt?> {
        Binding(
            get: { importPipeline.activePrompt },
            set: { newValue in
                if newValue == nil {
                    importPipeline.dismissPrompt()
                }
            }
        )
    }

    private var importPipelineAlertBinding: Binding<ImportPipelineAlert?> {
        Binding(
            get: { importPipeline.alert },
            set: { newValue in
                if newValue == nil {
                    importPipeline.dismissAlert()
                }
            }
        )
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

private struct LibrarySheetPresentation: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showImporter: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?
    @Binding var showSortSheet: Bool
    @Binding var importRootPrompt: ImportRootPrompt?
    let onImportPicked: ([URL]) -> Void
    let onCancelImportChoice: () -> Void
    let onConfirmImportChoice: ([GameImportValidator.ImportRootChoice]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showImporter) {
                DocumentPickerView { urls in
                    onImportPicked(urls)
                }
            }
            .sheet(item: $gameForSettings) { game in
                GameSettingsView(game: game)
            }
            .sheet(item: $gameForInfo) { game in
                GameInfoView(game: game)
            }
            .sheet(isPresented: $showSortSheet) {
                LibrarySortSheet(isPresented: $showSortSheet)
            }
            .sheet(item: $importRootPrompt) { prompt in
                ImportRootPickerSheet(
                    prompt: prompt,
                    onCancel: onCancelImportChoice,
                    onConfirm: onConfirmImportChoice
                )
            }
    }
}

private struct LibraryAlertPresentation: ViewModifier {
    let title: String
    let errorMessage: String?
    @Binding var showErrorAlert: Bool
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var showInvalidAlert: Bool
    @Binding var showCancelValidationAlert: Bool
    @Binding var showPausedGameAlert: Bool
    @Binding var importPipelineAlert: ImportPipelineAlert?
    let pausedGame: GameEntry?
    let onDeleteGame: () -> Void
    let onDismissImportPipelineAlert: () -> Void
    let onCancelValidation: () -> Void
    let onDismissPausedGameAlert: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(item: $importPipelineAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"), action: onDismissImportPipelineAlert)
                )
            }
            .alert(title, isPresented: $showErrorAlert) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
            .alert("Delete Game?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive, action: onDeleteGame)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } message: {
                if let game = gameToDelete {
                    Text(
                        "This will remove all files for \"\(game.title)\". You can always re-import it later."
                    )
                }
            }
            .alert("Invalid Game", isPresented: $showInvalidAlert) {
                Button("OK") {}
            } message: {
                Text("This game couldn't be loaded properly. You can delete it and try importing again.")
            }
            .alert("Cancel import?", isPresented: $showCancelValidationAlert) {
                Button("Keep importing", role: .cancel) {}
                Button("Cancel import", role: .destructive, action: onCancelValidation)
            } message: {
                Text("The game is still being validated. Cancelling will stop the import.")
            }
            .alert("A game is paused", isPresented: $showPausedGameAlert) {
                Button("OK", role: .cancel, action: onDismissPausedGameAlert)
                // "Quit and play" disabled until cross-session Ruby
                // state cleanup is reliable. See ExperimentalFeature
                // comment in AppSettings.swift. Users have to resume
                // the paused game (tapping its card) or force-close
                // the app to play a different one.
                // Button("Quit and play") {
                //     guard let game = pendingGame else { return }
                //     pendingGame = nil
                //     appState.returnToLibrary()
                //     appState.selectGame(game)
                //     path.append(game)
                // }
            } message: {
                if let pausedGame {
                    Text(
                        "\"\(pausedGame.title)\" is still running. Resume it from its card, or force-close the app to play a different game."
                    )
                }
            }
    }
}
