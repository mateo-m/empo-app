import SwiftUI

struct GameLibraryView: View {
    var appState: AppState
    var heroNamespace: Namespace.ID
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

    private var showEmpty: Bool {
        library.games.isEmpty
    }

    private var filteredGames: [GameEntry] {
        if searchText.isEmpty { return library.games }
        return library.games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var columns: [GridItem] {
        let count = verticalSizeClass == .compact ? 5 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                if !showEmpty {
                    gameContent
                        .transition(.opacity)
                } else {
                    Spacer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 8) {
                    libraryHeader
                    if !showEmpty {
                        searchBar
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: showEmpty)
            .overlay {
                if showEmpty {
                    emptyStateContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -30)
                        .transition(.emptyState)
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
            .navigationDestination(for: GameEntry.self) { game in
                GameLoadingView(game: game)
                    .navigationTransition(.zoom(sourceID: game.id, in: heroNamespace))
            }
            .onChange(of: appState.phase) { _, newPhase in
                if newPhase == .library && !path.isEmpty {
                    path = NavigationPath()
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Games Yet")
                .font(.title2)
                .fontWeight(.medium)
            Text("Add your favorite RPG Maker\ngames to get started!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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
            Spacer()
            Text("Library")
                .font(.title)
                .fontWeight(.bold)
            Spacer()
            // Invisible placeholder to keep "Library" centered
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal)
        .frame(height: headerHeight)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
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
                }
            }
            .padding(.horizontal, 12)
            .frame(height: searchBarHeight)
            .glassEffect(.regular.interactive(), in: .capsule)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    settings.libraryDisplayMode = settings.libraryDisplayMode == .grid ? .list : .grid
                }
            } label: {
                Image(systemName: settings.libraryDisplayMode == .grid ? "list.bullet" : "square.grid.2x2")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .contentTransition(.symbolEffect(.replace))
            }
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
        .tint(.primary)
    }

    // MARK: - Morphing Import Button

    private var importButton: some View {
        GeometryReader { geo in
            let collapsed = !showEmpty
            let buttonSize: CGFloat = 38

            // End positions (center coordinates)
            let collapsedX = geo.size.width - 16 - buttonSize / 2
            let collapsedY = headerHeight / 2
            let expandedX = geo.size.width / 2
            let expandedY = geo.size.height / 2 + 80

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
            .glassEffect(.regular.tint(.orange).interactive(), in: .capsule)
            .environment(\.colorScheme, .dark)
            // Counter-rotate to keep content upright
            .rotationEffect(.degrees(collapsed ? -arcDeg : 0))
            // Offset from arc center to expanded position
            .offset(x: offX, y: offY)
            // Arc sweep rotation
            .rotationEffect(.degrees(collapsed ? arcDeg : 0))
            // Place at arc center
            .position(x: arcCenterX, y: arcCenterY)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.55, bounce: 0.175), value: showEmpty)
        }
    }

    // MARK: - Game Content

    private var gameContent: some View {
        Group {
            if settings.libraryDisplayMode == .grid {
                gridContent
            } else {
                listContent
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                gridItems
            }
            .padding(.horizontal)
            .padding(.top, headerHeight + searchBarHeight + 20)
            .padding(.bottom)
            .animation(.default, value: filteredGames.map(\.id))
        }
    }

    private var listContent: some View {
        List {
            ForEach(filteredGames) { game in
                switch game.status {
                case .importing:
                    GameListRow(game: game, onStopImport: {
                        gameToDelete = game
                        showDeleteConfirm = true
                    })
                    .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)

                case .invalid:
                    GameListRow(game: game)
                        .onTapGesture { showInvalidAlert = true }
                        .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)

                case .ready:
                    GameListRow(game: game)
                        .matchedTransitionSource(id: game.id, in: heroNamespace)
                        .onTapGesture {
                            appState.selectGame(game)
                            path.append(game)
                        }
                        .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
                }
            }
            .onDelete { indexSet in
                if let index = indexSet.first {
                    gameToDelete = filteredGames[index]
                    showDeleteConfirm = true
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, headerHeight + searchBarHeight + 20, for: .scrollContent)
    }

    @ViewBuilder
    private var gridItems: some View {
        ForEach(filteredGames) { game in
            switch game.status {
            case .importing:
                GameCard(game: game, onStopImport: {
                    gameToDelete = game
                    showDeleteConfirm = true
                })
                    .id("\(game.id)-importing")
                    .transition(.cardAppear)

            case .invalid:
                Button { showInvalidAlert = true } label: {
                    GameCard(game: game)
                }
                    .id("\(game.id)-invalid")
                    .buttonStyle(CardPressStyle())
                    .transition(.cardAppear)
                    .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)

            case .ready:
                NavigationLink(value: game) {
                    GameCard(game: game)
                        .matchedTransitionSource(id: game.id, in: heroNamespace)
                }
                    .id("\(game.id)-ready")
                    .buttonStyle(CardPressStyle())
                    .simultaneousGesture(TapGesture().onEnded {
                        appState.selectGame(game)
                    })
                    .transition(.cardAppear)
                    .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm, gameForSettings: $gameForSettings, gameForInfo: $gameForInfo)
            }
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
                }
            }
        }
    }
}

// MARK: - Transitions

private struct EmptyStateModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.8 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 10 : 0)
    }
}

private struct CardTransitionModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.97 : 1)
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 6 : 0)
    }
}

extension AnyTransition {
    static var emptyState: AnyTransition {
        .modifier(
            active: EmptyStateModifier(active: true),
            identity: EmptyStateModifier(active: false)
        )
    }

    static var cardAppear: AnyTransition {
        .modifier(
            active: CardTransitionModifier(active: true),
            identity: CardTransitionModifier(active: false)
        )
    }
}

// MARK: - Game Context Menu

private struct GameContextMenuModifier: ViewModifier {
    let game: GameEntry
    @Binding var gameToDelete: GameEntry?
    @Binding var showDeleteConfirm: Bool
    @Binding var gameForSettings: GameEntry?
    @Binding var gameForInfo: GameEntry?

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

            Divider()

            Button(role: .destructive) {
                gameToDelete = game
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension View {
    func gameContextMenu(game: GameEntry, gameToDelete: Binding<GameEntry?>, showDeleteConfirm: Binding<Bool>, gameForSettings: Binding<GameEntry?>, gameForInfo: Binding<GameEntry?>) -> some View {
        modifier(GameContextMenuModifier(game: game, gameToDelete: gameToDelete, showDeleteConfirm: showDeleteConfirm, gameForSettings: gameForSettings, gameForInfo: gameForInfo))
    }
}
