import SwiftUI

struct GameLibraryView: View {
    var appState: AppState
    var heroNamespace: Namespace.ID
    var splashDismissed: Bool = true
    var library = GameLibrary.shared
    var settings = AppSettings.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var errorMessage: String?
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
    @State private var importGlowing = false
    @State private var importMoveTrigger = 0
    /// Extra delay for content entrance on first mount (after splash).
    @State private var entranceDelay: TimeInterval = 0.15
    @State private var importRevealed = false
    @State private var importShimmer: CGFloat = -1

    private var showEmpty: Bool {
        library.games.isEmpty
    }

    private var filteredGames: [GameEntry] {
        if searchText.isEmpty { return library.games }
        return library.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    /// The most recently played game, if any (only shown when not searching).
    private var recentlyPlayed: GameEntry? {
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
                        .offset(y: -30)
                        .transition(.emptyState)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: Spacing.md) {
                    libraryHeader
                    if !showEmpty {
                        searchBar
                    }
                }
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
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
                // Warm gradient background — subtle brand warmth
                LinearGradient(
                    colors: [.brand.opacity(0.06), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            }
            .animation(Motion.standard, value: showEmpty)
            .onChange(of: splashDismissed) { _, dismissed in
                if dismissed {
                    staggerTrigger = UUID()
                    withAnimation(.spring(duration: 0.35, bounce: 0.2).delay(entranceDelay + 0.1)) {
                        importRevealed = true
                    }
                    // Clear entrance delay after first mount so subsequent
                    // animations (view mode switch, new imports) play instantly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        entranceDelay = 0
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                importButton
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
            .alert("Oops!", isPresented: $showErrorAlert) {
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
                    if let game = pendingGame {
                        pendingGame = nil
                        appState.returnToLibrary()
                        // Small delay to let the engine tear down before starting new game
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            appState.selectGame(game)
                            path.append(game)
                        }
                    }
                }
            } message: {
                if let paused = appState.pausedGame {
                    Text("\"\(paused.title)\" is still running. Quit it to play a different game?")
                }
            }
            .navigationDestination(for: GameEntry.self) { game in
                GameLoadingView(game: game)
                    .navigationTransition(.zoom(sourceID: game.id, in: heroNamespace))
            }
            .onChange(of: appState.phase) { _, newPhase in
                if newPhase == nil && !path.isEmpty {
                    path = NavigationPath()
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateContent: some View {
        EmptyStateView(
            icon: "gamecontroller",
            title: "No Games Yet",
            subtitle: "Add your favorite RPG Maker\ngames to get started!",
            revealed: splashDismissed,
            initialDelay: entranceDelay
        )
    }

    // MARK: - Header

    private let headerHeight: CGFloat = 56
    private let searchBarHeight: CGFloat = 44

    private var libraryHeader: some View {
        HStack {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .padding(10)
            }
            .tint(.primary)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Settings")
            Spacer()
            Text("Library")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
            // Invisible placeholder to keep "Library" centered
            Color.clear.frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .frame(height: headerHeight)
    }

    // MARK: - Search Bar

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

            Button {
                withAnimation(Motion.standard) {
                    settings.libraryDisplayMode = settings.libraryDisplayMode == .grid ? .list : .grid
                }
                // Trigger stagger after new views mount
                DispatchQueue.main.async {
                    staggerTrigger = UUID()
                }
            } label: {
                Image(systemName: settings.libraryDisplayMode == .grid ? "list.bullet" : "square.grid.2x2")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: AppSize.toolbarButton, height: AppSize.toolbarButton)
                    .contentTransition(.symbolEffect(.replace))
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(settings.libraryDisplayMode == .grid ? "Switch to list" : "Switch to grid")
        }
        .padding(.horizontal)
        .padding(.bottom, Spacing.xs)
        .tint(.primary)
    }

    // MARK: - Morphing Import Button

    private var importButton: some View {
        GeometryReader { geo in
            let collapsed = !showEmpty
            let buttonSize: CGFloat = AppSize.toolbarButton

            // End positions (center coordinates)
            let collapsedX = geo.size.width - 16 - buttonSize / 2
            let collapsedY = headerHeight / 2
            let expandedX = geo.size.width / 2
            let expandedY = geo.size.height / 2 + 110

            // Arc: find center of rotation on perpendicular bisector
            let chordDX = collapsedX - expandedX
            let chordDY = collapsedY - expandedY
            let curvature: CGFloat = -1.5 // larger = gentler/subtler arc
            let arcCenterX = (expandedX + collapsedX) / 2 + curvature * (-chordDY)
            let arcCenterY = (expandedY + collapsedY) / 2 + curvature * chordDX

            // Offset from arc center to expanded position
            let offX = expandedX - arcCenterX
            let offY = expandedY - arcCenterY

            // Arc sweep angle (expanded → collapsed)
            let startAngle = atan2(offY, offX)
            let endAngle = atan2(collapsedY - arcCenterY, collapsedX - arcCenterX)
            let arcDeg = (endAngle - startAngle) * 180 / .pi

            Button(action: { showImporter = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    if !collapsed {
                        Text("Import game")
                            .font(.body.weight(.semibold))
                            .transition(.blurReplace)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, collapsed ? 10 : 20)
                .padding(.vertical, collapsed ? 10 : 12)
            }
            .glassEffect(.regular.tint(.brand).interactive(), in: .capsule)
            .overlay {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.25), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: UnitPoint(x: importShimmer - 0.3, y: importShimmer - 0.3),
                            endPoint: UnitPoint(x: importShimmer, y: importShimmer)
                        )
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .brand.opacity(collapsed ? 0 : (importGlowing ? 0.5 : 0.15)),
                    radius: collapsed ? 0 : (importGlowing ? 16 : 6))
            .environment(\.colorScheme, .dark)
            // Scale-based reveal: glass effect initializes at near-zero scale
            // (fully tinted but invisible), avoiding the gray flash that
            // opacity-based reveals cause.
            .scaleEffect(importRevealed ? 1 : 0.001)
            .allowsHitTesting(importRevealed)
            .keyframeAnimator(
                initialValue: ImportButtonSquash(),
                trigger: importMoveTrigger
            ) { content, value in
                content.scaleEffect(x: value.scaleX, y: value.scaleY)
            } keyframes: { _ in
                KeyframeTrack(\.scaleX) {
                    SpringKeyframe(1.18, duration: 0.12, spring: .snappy)
                    SpringKeyframe(0.92, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
                KeyframeTrack(\.scaleY) {
                    SpringKeyframe(0.85, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.08, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                }
            }
            // Counter-rotate to keep content upright
            .rotationEffect(.degrees(collapsed ? -arcDeg : 0))
            // Offset from arc center to expanded position
            .offset(x: offX, y: offY)
            // Arc sweep rotation
            .rotationEffect(.degrees(collapsed ? arcDeg : 0))
            // Place at arc center
            .position(x: arcCenterX, y: arcCenterY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: showEmpty)
            .onChange(of: showEmpty) { importMoveTrigger += 1 }
            .onAppear {
                if splashDismissed {
                    importRevealed = true
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        importGlowing = true
                    }
                }
            }
            .onChange(of: importRevealed) {
                guard importRevealed else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    importGlowing = true
                }
                withAnimation(.easeInOut(duration: 1.5).delay(0.4)) {
                    importShimmer = 2
                }
            }
        }
    }

    // MARK: - Game Content

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
            // Hero card for recently played game
            if let hero = recentlyPlayed {
                heroCard(for: hero)
                    .transition(.cardAppear)
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

    // MARK: - Hero Card

    private func heroCard(for game: GameEntry) -> some View {
        let isPaused = appState.pausedGame?.id == game.id
        return Button { handleGameTap(game) } label: {
            Color.clear
                .aspectRatio(2.2, contentMode: .fit)
                .overlay {
                    GameArtworkView(
                        artworkPath: game.artworkPath,
                        importing: false,
                        shimmer: false
                    )
                }
                .overlay {
                    // Gradient scrim for readability
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
        .gameContextMenu(game: game, appState: appState, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
    }

    private var listInner: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(filteredGames.enumerated()), id: \.element.id) { index, game in
                let isPaused = appState.pausedGame?.id == game.id
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
                .disabled(game.isImporting)
                .gameContextMenu(game: game, appState: appState, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
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
                    .gameContextMenu(game: game, appState: appState, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
                    .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)

            case .ready:
                let isPaused = appState.pausedGame?.id == game.id
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
                .gameContextMenu(game: game, appState: appState, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
                .staggered(index: index, trigger: staggerTrigger, initialDelay: entranceDelay)
            }
        }
    }

    // MARK: - Game Tap Handling

    /// Centralized tap handler for game cards in both grid and list modes.
    private func handleGameTap(_ game: GameEntry) {
        if appState.pausedGame?.id == game.id {
            // Resume the paused game
            appState.resume()
            path.append(game)
        } else if appState.pausedGame != nil {
            // Another game is paused — confirm before switching
            pendingGame = game
            showPausedGameAlert = true
        } else {
            // Normal: start the game
            appState.selectGame(game)
            path.append(game)
        }
    }

    // MARK: - Import

    private func importGames(from urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()

            library.importGame(from: url) { error in
                if accessing { url.stopAccessingSecurityScopedResource() }
                if let error = error {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                } else {
                    Haptics.impact()
                }
            }
        }
    }
}

// Transitions (EmptyState, CardAppear) are defined in Design/Primitives.swift

// MARK: - Game Context Menu

private struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    var appState: AppState
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?

    private var isPaused: Bool { appState.pausedGame?.id == game.id }

    func body(content: Content) -> some View {
        content.contextMenu {
            if case .ready = game.status {
                Button {
                    gameForInfo = game
                } label: {
                    Label("Info", systemImage: "info.circle")
                }

                Button {
                    gameForSettings = game
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            if isPaused {
                Divider()

                Button(role: .destructive) {
                    appState.returnToLibrary()
                } label: {
                    Label("Quit", systemImage: "stop.fill")
                }
            }

            Divider()

            Button(role: .destructive) {
                gameToDelete = game
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .tint(nil)
    }
}

// MARK: - Import Button Squash-and-Stretch

private struct ImportButtonSquash {
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
}

extension View {
    func gameContextMenu(game: GameEntry, appState: AppState, gameToDelete: Binding<GameEntry?>, showDeleteConfirm: Binding<Bool>, gameForSettings: Binding<GameEntry?>, gameForInfo: Binding<GameEntry?>) -> some View {
        modifier(GameContextMenuModifier(game: game, appState: appState, gameToDelete: gameToDelete, showDeleteConfirm: showDeleteConfirm, gameForSettings: gameForSettings, gameForInfo: gameForInfo))
    }
}
