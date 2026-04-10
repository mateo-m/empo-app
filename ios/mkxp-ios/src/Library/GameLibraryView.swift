import SwiftUI

struct GameLibraryView: View {
    @ObservedObject var appState: AppState
    var heroNamespace: Namespace.ID
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var settings = AppSettings.shared
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

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Custom header — stays put during hero zoom (no nav bar animation)
                HStack {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .padding(10)
                    }
                    .glassEffect(.regular, in: .circle)
                    Spacer()
                    Text("Library")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { showImporter = true }) {
                        Image(systemName: "plus")
                            .font(.body)
                            .padding(10)
                    }
                    .glassEffect(.regular, in: .circle)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if !showEmpty {
                    gameGrid
                        .transition(.opacity)
                } else {
                    Spacer()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showEmpty)
            .overlay {
                if showEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.emptyState)
                }
            }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showImporter) {
                DocumentPickerView { url in
                    importGame(from: url)
                }
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .alert("Delete Game", isPresented: $showDeleteConfirm) {
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
                    Text("Are you sure you want to delete \"\(game.title)\"? This will remove all game files.")
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Games")
                .font(.title2)
                .fontWeight(.medium)
            Text("Tap + to import an RPG Maker game folder or .zip file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: 240)
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(library.games) { game in
                    if game.isImporting {
                        GameCard(game: game)
                            .transition(.cardAppear)
                    } else {
                        NavigationLink(value: game) {
                            GameCard(game: game)
                                .matchedTransitionSource(id: game.id, in: heroNamespace)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            appState.selectGame(game)
                        })
                        .contextMenu {
                            Button(role: .destructive) {
                                gameToDelete = game
                                showDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .transition(.cardAppear)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical)
            .animation(.default, value: library.games.map(\.id))
        }
    }

    // MARK: - Import

    private func importGame(from url: URL) {
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
