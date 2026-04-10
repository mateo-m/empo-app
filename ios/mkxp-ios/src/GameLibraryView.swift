import SwiftUI
import UniformTypeIdentifiers

struct GameLibraryView: View {
    @ObservedObject var appState: AppState
    var heroNamespace: Namespace.ID
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var importError: String?
    @State private var showError = false
    @State private var gameToDelete: GameEntry?
    @State private var showDeleteConfirm = false
    @State private var path = NavigationPath()

    private var isImporting: Bool { library.importStatus != nil }

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

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
                    .disabled(isImporting)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ZStack {
                    Group {
                        if library.games.isEmpty && !isImporting {
                            emptyState
                        } else {
                            gameGrid
                        }
                    }

                    if isImporting {
                        importOverlay
                    }
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showImporter) {
                DocumentPickerView { url in
                    importGame(from: url)
                }
            }
            .alert("Import Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(importError ?? "Unknown error")
            }
            .alert("Delete Game", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let game = gameToDelete {
                        library.deleteGame(game)
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

    // MARK: - Import Overlay

    private var importOverlay: some View {
        VStack(spacing: 16) {
            ProgressView(value: library.importProgress)
                .progressViewStyle(.linear)
            if settings.debugMode {
                Text(library.importStatus ?? "Importing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                Text("Importing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 240)
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.games) { game in
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
                }
            }
            .padding()
        }
    }

    // MARK: - Import

    private func importGame(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()

        library.importGame(from: url) { error in
            if accessing { url.stopAccessingSecurityScopedResource() }
            if let error = error {
                importError = error.localizedDescription
                showError = true
            }
        }
    }
}

// MARK: - Game Card

struct GameCard: View {
    let game: GameEntry

    var body: some View {
        VStack(spacing: 0) {
            artworkView
                .frame(height: 160)
                .clipped()

            Text(game.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let path = game.artworkPath, let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(.tertiarySystemBackground)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Debug Mode", isOn: $settings.debugMode)
                } footer: {
                    Text("Shows detailed file names during import and other verbose information.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Loading View (pushed inside NavigationStack with zoom hero transition)

struct GameLoadingView: View {
    let game: GameEntry

    var body: some View {
        ZStack {
            // Blurred, dimmed artwork background
            artworkBackground

            // Title + spinner centered
            VStack(spacing: 16) {
                Text(game.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(radius: 4)

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var artworkBackground: some View {
        if let path = game.artworkPath, let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .blur(radius: 20)
                .overlay(Color.black.opacity(0.5))
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

// MARK: - Document Picker (UIKit wrapper)

struct DocumentPickerView: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
