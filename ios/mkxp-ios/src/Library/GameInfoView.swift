import SwiftUI

struct GameInfoView: View {
    let game: GameEntry
    var library = GameLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var metadata: GameMetadata
    @State private var editingTitle: String
    @State private var diskSize: Int64?
    @State private var showArtworkPicker = false
    @State private var showBannerPicker = false
    @State private var isEditingTitle = false
    @State private var titleScrollProgress: CGFloat = 0
    @State private var navBarBottomY: CGFloat = 0
    @State private var needsLibraryRefresh = false
    @FocusState private var isTitleFocused: Bool

    /// The Game.ini title (before custom override) — shown as subtitle.
    private let originalTitle: String

    init(game: GameEntry) {
        self.game = game
        let meta = GameMetadata.load(for: game.id)
        _metadata = State(initialValue: meta)
        _editingTitle = State(initialValue: meta.customTitle ?? "")

        // Read the original Game.ini title (ignoring custom overrides)
        let gameDir = URL(fileURLWithPath: game.path)
        let fm = FileManager.default
        let iniURL: URL? = {
            let gameIni = gameDir.appendingPathComponent("Game.ini")
            if fm.fileExists(atPath: gameIni.path) { return gameIni }
            if let items = try? fm.contentsOfDirectory(atPath: gameDir.path) {
                for item in items where item.lowercased().hasSuffix(".ini") {
                    return gameDir.appendingPathComponent(item)
                }
            }
            return nil
        }()

        var iniTitle = "Unknown Game"
        if let iniURL, let data = try? String(contentsOf: iniURL, encoding: .utf8) {
            var inGameSection = false
            for line in data.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    inGameSection = trimmed.lowercased().hasPrefix("[game]")
                    continue
                }
                if inGameSection && trimmed.lowercased().hasPrefix("title=") {
                    let value = String(trimmed.dropFirst("title=".count))
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { iniTitle = value }
                    break
                }
            }
        }
        self.originalTitle = iniTitle
    }

    // MARK: - Computed

    private var bannerImage: UIImage? {
        guard let path = metadata.customBannerPath(for: game.id) else { return nil }
        return ImageCache.shared.image(for: path)
    }

    private var artworkImage: UIImage? {
        if let path = metadata.customArtworkPath(for: game.id) {
            return ImageCache.shared.image(for: path)
        }
        if let path = game.artworkPath {
            return ImageCache.shared.image(for: path)
        }
        return nil
    }

    private var hasCustomArtwork: Bool {
        metadata.customArtworkFilename != nil
    }

    private var hasCustomBanner: Bool {
        metadata.customBannerFilename != nil
    }

    private var displayTitle: String {
        metadata.customTitle ?? originalTitle
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Banner (full-bleed via zero section margins) ──
                Section {
                    bannerHeader
                }
                .listSectionMargins(.all, 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listSectionSeparator(.hidden)

                // ── Details ──────────────────────────────
                Section("Details") {
                    LabeledContent("Date added") {
                        if let date = metadata.dateAdded {
                            Text(Self.dateFormatter.string(from: date))
                        } else {
                            Text("Unknown")
                        }
                    }

                    LabeledContent("Last played") {
                        if let date = metadata.lastPlayed {
                            Text(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
                        } else {
                            Text("Never")
                        }
                    }

                    if let time = metadata.totalPlayTime, time > 0 {
                        LabeledContent("Play time") {
                            Text(GameMetadata.formatPlayTime(metadata.totalPlayTime))
                        }
                    }

                    LabeledContent("Size on disk") {
                        if let size = diskSize {
                            Text(GameMetadata.formatDiskSize(size))
                        } else {
                            ProgressView()
                        }
                    }

                    LabeledContent("ID") {
                        Text(game.id)
                            .monospaced()
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                // ── Actions ──────────────────────────────
                Section {
                    Button { openInFiles() } label: {
                        Label("Browse game files", systemImage: "folder")
                    }

                    if let logURL = sessionLogURL() {
                        ShareLink(item: logURL) {
                            Label("Export logs", systemImage: "square.and.arrow.up")
                        }
                    }

                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListHeaderHeight, 0)
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(titleScrollProgress > 0.5 ? .visible : .hidden, for: .navigationBar)
            .animation(.smooth(duration: 0.15), value: titleScrollProgress > 0.5)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        // Title slides in: frame height grows to push subtitle down,
                        // opacity fades in so no visible clipping needed.
                        Text(displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .frame(height: 20 * titleScrollProgress, alignment: .bottom)
                            .opacity(titleScrollProgress)

                        // Subtitle: cross-fade between headline and caption sizes
                        // (font changes aren't animatable, so we overlay both)
                        ZStack {
                            Text("Information")
                                .font(.headline)
                                .opacity(1 - titleScrollProgress)
                                .blur(radius: titleScrollProgress * 4)

                            Text("Information")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .opacity(titleScrollProgress)
                        }
                    }
                    .frame(maxWidth: 250)
                    .animation(.smooth(duration: 0.2), value: titleScrollProgress)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear {
                                navBarBottomY = geo.frame(in: .global).maxY
                            }
                        }
                    )
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .tint(.orange)
                }
            }
            .imageSourcePicker(
                isPresented: $showArtworkPicker,
                title: "Game artwork",
                hasExisting: hasCustomArtwork,
                onImageSelected: { saveArtwork($0) },
                onRemove: { removeArtwork() }
            )
            .imageSourcePicker(
                isPresented: $showBannerPicker,
                title: "Game banner",
                hasExisting: hasCustomBanner,
                onImageSelected: { saveBanner($0) },
                onRemove: { removeBanner() }
            )
            .task {
                diskSize = await GameMetadata.diskSize(
                    for: URL(fileURLWithPath: game.path)
                )
            }
            .onDisappear {
                if needsLibraryRefresh {
                    library.refreshGameEntry(id: game.id)
                }
            }
        }
        .onKeyPress(.escape) {
            if isEditingTitle {
                finishEditingTitle()
                return .handled
            }
            return .ignored
        }
        .tint(.orange)
    }

    // MARK: - Banner Header

    private let bannerHeight: CGFloat = 260

    private var bannerHeader: some View {
        ZStack(alignment: .bottomLeading) {
            // Banner image with gradient fade-out mask
            bannerBackground
                .contentShape(Rectangle())
                .onTapGesture { showBannerPicker = true }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.4),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(alignment: .topTrailing) {
                    Label("Change banner", systemImage: "photo")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .opacity(0.5)
                        .padding(.top, 72)
                        .padding(.trailing, 16)
                        .opacity(1 - titleScrollProgress)
                }

            // Artwork + Title overlay (unaffected by mask)
            HStack(spacing: 14) {
                artworkView
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "photo")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(6)
                            .glassEffect(.regular, in: .circle)
                            .opacity(0.5)
                            .padding(4)
                    }
                    .shadow(radius: 8, y: 4)
                    .contentShape(Rectangle())
                    .onTapGesture { showArtworkPicker = true }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isEditingTitle {
                            TextField(originalTitle, text: $editingTitle)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .focused($isTitleFocused)
                                .onSubmit { finishEditingTitle() }
                                .onChange(of: isTitleFocused) { _, focused in
                                    if !focused { finishEditingTitle() }
                                }
                                .onAppear { isTitleFocused = true }
                        } else {
                            Text(displayTitle)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Image(systemName: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .glassEffect(.regular, in: .circle)
                                .opacity(0.4)
                        }
                    }

                    if metadata.customTitle != nil, !isEditingTitle {
                        Text(originalTitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingTitle = metadata.customTitle ?? ""
                    isEditingTitle = true
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .contentShape(Rectangle())
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.frame(in: .global).minY) { _, globalY in
                        // Start the animation when the title overlay reaches
                        // the nav bar bottom edge (measured dynamically).
                        guard navBarBottomY > 0 else { return }
                        let transitionRange: CGFloat = 40
                        let progress = max(0, min(1, (navBarBottomY - globalY) / transitionRange))
                        titleScrollProgress = progress
                    }
                }
            )
        }
        .frame(height: bannerHeight)
        .clipped()
    }

    /// Banner background — custom banner, or game artwork scaled to fill, or gradient.
    @ViewBuilder
    private var bannerBackground: some View {
        if let banner = bannerImage {
            Image(uiImage: banner)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: bannerHeight)
        } else if let artwork = artworkImage {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: bannerHeight)
        } else {
            LinearGradient(
                colors: [.orange.opacity(0.4), .purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: bannerHeight)
        }
    }

    private var artworkView: some View {
        Group {
            if let artwork = artworkImage {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Formatters

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: - Actions

    private func finishEditingTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.customTitle = title.isEmpty ? nil : title
        metadata.save(for: game.id)
        needsLibraryRefresh = true
    }

    private func saveArtwork(_ image: UIImage) {
        if let path = metadata.customArtworkPath(for: game.id) {
            ImageCache.shared.evict(path: path)
        }
        guard let filename = GameMetadata.saveImage(image, as: "artwork", for: game.id) else { return }
        metadata.customArtworkFilename = filename
        metadata.save(for: game.id)
        needsLibraryRefresh = true
    }

    private func removeArtwork() {
        if let path = metadata.customArtworkPath(for: game.id) {
            ImageCache.shared.evict(path: path)
        }
        if let filename = metadata.customArtworkFilename {
            GameMetadata.removeImage(named: filename, for: game.id)
        }
        metadata.customArtworkFilename = nil
        metadata.save(for: game.id)
        needsLibraryRefresh = true
    }

    private func saveBanner(_ image: UIImage) {
        if let path = metadata.customBannerPath(for: game.id) {
            ImageCache.shared.evict(path: path)
        }
        guard let filename = GameMetadata.saveImage(image, as: "banner", for: game.id) else { return }
        metadata.customBannerFilename = filename
        metadata.save(for: game.id)
    }

    private func removeBanner() {
        if let path = metadata.customBannerPath(for: game.id) {
            ImageCache.shared.evict(path: path)
        }
        if let filename = metadata.customBannerFilename {
            GameMetadata.removeImage(named: filename, for: game.id)
        }
        metadata.customBannerFilename = nil
        metadata.save(for: game.id)
    }

    private func openInFiles() {
        let encoded = game.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? game.path
        if let url = URL(string: "shareddocuments://\(encoded)") {
            UIApplication.shared.open(url)
        }
    }

    private func sessionLogURL() -> URL? {
        let logsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let historyLog = logsDir.appendingPathComponent("session-history.log")
        return FileManager.default.fileExists(atPath: historyLog.path) ? historyLog : nil
    }
}
