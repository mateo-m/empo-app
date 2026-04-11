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
    @State private var path = NavigationPath()

    private var showEmpty: Bool {
        library.games.isEmpty
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
                    gameGrid
                        .transition(.opacity)
                } else {
                    Spacer()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                libraryHeader
            }
            .animation(.easeInOut(duration: 0.25), value: showEmpty)
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
            .alert("oops!", isPresented: $showErrorAlert) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Something went wrong.")
            }
            .alert("delete game?", isPresented: $showDeleteConfirm) {
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
            Text("no games yet")
                .font(.title2)
                .fontWeight(.medium)
            Text("add your favorite RPG Maker\ngames to get started!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Header

    private let headerHeight: CGFloat = 56

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
            Text("library")
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            // Invisible placeholder to keep "Library" centered
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal)
        .frame(height: headerHeight)
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

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(library.games) { game in
                    if game.isImporting {
                        GameCard(game: game, onStopImport: {
                            gameToDelete = game
                            showDeleteConfirm = true
                        })
                            .id("\(game.id)-importing")
                            .transition(.cardAppear)
                    } else {
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
                        .gameContextMenu(game: game, gameToDelete: $gameToDelete, showDeleteConfirm: $showDeleteConfirm)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, headerHeight + 8)
            .padding(.bottom)
            .animation(.default, value: library.games.map(\.id))
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
            .scaleEffect(active ? 0.9 : 1)
            .opacity(active ? 0.8 : 1)
            .blur(radius: active ? 4 : 0)
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

    func body(content: Content) -> some View {
        content.contextMenu {
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
    func gameContextMenu(game: GameEntry, gameToDelete: Binding<GameEntry?>, showDeleteConfirm: Binding<Bool>) -> some View {
        modifier(GameContextMenuModifier(game: game, gameToDelete: gameToDelete, showDeleteConfirm: showDeleteConfirm))
    }
}
