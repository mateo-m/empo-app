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
        self.originalTitle = GameEntry.parseINITitle(at: gameDir) ?? "Unknown Game"
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
            .animation(.smooth(duration: Motion.durationFast), value: titleScrollProgress > 0.5)
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
                    .animation(.smooth(duration: Motion.durationNormal), value: titleScrollProgress)
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
                        .tint(.brand)
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
        .tint(.brand)
    }

    // MARK: - Banner Header

    private let bannerHeight: CGFloat = 260

    private var bannerHeader: some View {
        ZStack(alignment: .bottomLeading) {
            // Banner image with gradient fade-out mask
            bannerBackground
                .contentShape(Rectangle())
                .onTapGesture { showBannerPicker = true }
                .accessibilityLabel("Change banner image")
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
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .opacity(0.5)
                        .padding(.top, 72)
                        .padding(.trailing, Spacing.xl)
                        .opacity(1 - titleScrollProgress)
                }

            // Artwork + Title overlay (unaffected by mask)
            HStack(spacing: 14) {
                artworkView
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "photo")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(Spacing.sm)
                            .glassEffect(.regular, in: .circle)
                            .opacity(0.5)
                            .padding(Spacing.xs)
                    }
                    .elevatedShadow()
                    .contentShape(Rectangle())
                    .onTapGesture { showArtworkPicker = true }
                    .accessibilityLabel("Change game artwork")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Spacing.sm) {
                        if isEditingTitle {
                            TextField(originalTitle, text: $editingTitle)
                                .font(.title2.weight(.bold))
                                .focused($isTitleFocused)
                                .onSubmit { finishEditingTitle() }
                                .onChange(of: isTitleFocused) { _, focused in
                                    if !focused { finishEditingTitle() }
                                }
                                .onAppear { isTitleFocused = true }
                        } else {
                            Text(displayTitle)
                                .font(.title2.weight(.bold))
                                .lineLimit(1)

                            Image(systemName: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .glassEffect(.regular, in: .circle)
                                .opacity(Overlay.light + 0.1)
                        }
                    }

                    if metadata.customTitle != nil, !isEditingTitle {
                        Text(originalTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    editingTitle = metadata.customTitle ?? ""
                    isEditingTitle = true
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.bottom, Spacing.xxl)
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
            // Fallback gradient — adapts to color scheme via .surface
            LinearGradient(
                colors: [.brand.opacity(0.3), .surface],
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
        .frame(width: AppSize.infoArtwork, height: AppSize.infoArtwork)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
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

    private func saveCustomImage(_ image: UIImage, kind: String,
                                 pathGetter: (GameMetadata) -> String?,
                                 filenameSetter: (inout GameMetadata, String?) -> Void) {
        if let path = pathGetter(metadata) {
            ImageCache.shared.evict(path: path)
        }
        guard let filename = GameMetadata.saveImage(image, as: kind, for: game.id) else { return }
        filenameSetter(&metadata, filename)
        metadata.save(for: game.id)
        needsLibraryRefresh = true
    }

    private func removeCustomImage(kind: String,
                                   pathGetter: (GameMetadata) -> String?,
                                   filenameGetter: (GameMetadata) -> String?,
                                   filenameSetter: (inout GameMetadata, String?) -> Void) {
        if let path = pathGetter(metadata) {
            ImageCache.shared.evict(path: path)
        }
        if let filename = filenameGetter(metadata) {
            GameMetadata.removeImage(named: filename, for: game.id)
        }
        filenameSetter(&metadata, nil)
        metadata.save(for: game.id)
        needsLibraryRefresh = true
    }

    private func saveArtwork(_ image: UIImage) {
        saveCustomImage(image, kind: "artwork",
                       pathGetter: { $0.customArtworkPath(for: game.id) },
                       filenameSetter: { $0.customArtworkFilename = $1 })
    }

    private func removeArtwork() {
        removeCustomImage(kind: "artwork",
                         pathGetter: { $0.customArtworkPath(for: game.id) },
                         filenameGetter: { $0.customArtworkFilename },
                         filenameSetter: { $0.customArtworkFilename = $1 })
    }

    private func saveBanner(_ image: UIImage) {
        saveCustomImage(image, kind: "banner",
                       pathGetter: { $0.customBannerPath(for: game.id) },
                       filenameSetter: { $0.customBannerFilename = $1 })
    }

    private func removeBanner() {
        removeCustomImage(kind: "banner",
                         pathGetter: { $0.customBannerPath(for: game.id) },
                         filenameGetter: { $0.customBannerFilename },
                         filenameSetter: { $0.customBannerFilename = $1 })
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
