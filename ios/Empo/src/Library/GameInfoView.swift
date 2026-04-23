import SwiftUI

struct GameInfoView: View {
    let game: GameEntry
    @Environment(\.gameLibrary) private var library
    @Environment(\.tipStore) private var tipStore
    @Environment(\.appSettings) private var settings
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

    private let originalTitle: String

    init(game: GameEntry) {
        self.game = game
        let meta = GameMetadata.load(for: game.id)
        _metadata = State(initialValue: meta)
        _editingTitle = State(initialValue: meta.customTitle ?? "")

        let gameDir = URL(fileURLWithPath: game.path)
        // Title shown when the user hasn't set a customTitle. For
        // JGP imports this is the manifest name; for plain
        // folder/zip imports it's the Game.ini title. The label
        // under the text field (and the text-field placeholder)
        // both track this so resetting the custom title gives the
        // user back what the import originally showed, not the
        // raw Game.ini one which may be uglier.
        self.originalTitle = meta.baseTitle
            ?? GameEntry.parseINITitle(at: gameDir)
            ?? "Unknown Game"
    }

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
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        bannerHeader(insets: geo.safeAreaInsets)
                            .padding(.top, -geo.safeAreaInsets.top)
                            .padding(.leading, -geo.safeAreaInsets.leading)
                            .padding(.trailing, -geo.safeAreaInsets.trailing)

                    if tipStore.isVisible(.gameInfoCustomization) {
                        TipBanner(tip: .gameInfoCustomization)
                            .padding(.horizontal, Spacing._2xl)
                            .padding(.top, Spacing.xl)
                            .transition(.tipBanner)
                    }

                    GroupedSection("Details") {
                        DetailRow("Date added") {
                            if let date = metadata.dateAdded {
                                Text(Self.dateFormatter.string(from: date))
                            } else {
                                Text("Unknown")
                            }
                        }

                        Divider().padding(.leading, Spacing.xl)

                        DetailRow("Last played") {
                            if let date = metadata.lastPlayed {
                                Text(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
                            } else {
                                Text("Never")
                            }
                        }

                        if let time = metadata.totalPlayTime, time > 0 {
                            Divider().padding(.leading, Spacing.xl)

                            DetailRow("Play time") {
                                Text(GameMetadata.formatPlayTime(metadata.totalPlayTime))
                            }
                        }

                        Divider().padding(.leading, Spacing.xl)

                        DetailRow("Size on disk") {
                            if let size = diskSize {
                                Text(GameMetadata.formatDiskSize(size))
                            } else {
                                ProgressView()
                            }
                        }

                        Divider().padding(.leading, Spacing.xl)

                        DetailRow("Local ID") {
                            Text(game.id)
                                .monospaced()
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }

                    GroupedSection {
                        Button { openInFiles() } label: {
                            Label("Browse game files", systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.lg)
                        }

                    if let logURL = sessionLogURL(), settings.debugLogs {
                        Divider().padding(.leading, Spacing.xl)

                        ShareLink(item: logURL) {
                            Label("Export logs", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.vertical, Spacing.lg)
                        }
                    }
                    }
                }
            }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .animation(Motion.snappy, value: titleScrollProgress > 0.5)
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

                        // Subtitle cross-fades between headline and caption sizes.
                        // Font changes aren't animatable, so both are overlaid.
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
                    .animation(Motion.standard, value: titleScrollProgress)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .global).maxY
                    } action: { newValue in
                        navBarBottomY = newValue
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .tint(.brand)
                }
            }
            .imageSourcePicker(
                isPresented: $showArtworkPicker,
                title: "Artwork",
                hasExisting: hasCustomArtwork,
                onImageSelected: { saveArtwork($0) },
                onRemove: { removeArtwork() }
            )
            .imageSourcePicker(
                isPresented: $showBannerPicker,
                title: "Banner",
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

    private let bannerHeight: CGFloat = 260

    private func bannerHeader(insets: EdgeInsets) -> some View {
        ZStack(alignment: .bottomLeading) {
            bannerBackground
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle { finishEditingTitle() }
                    else { showBannerPicker = true }
                }
                .accessibilityAddTraits(.isButton)
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

            HStack(spacing: Spacing.lg) {
                artworkView
                    .elevatedShadow()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditingTitle { finishEditingTitle() }
                        else { showArtworkPicker = true }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Change game artwork")

                VStack(alignment: .leading, spacing: Spacing.xxs) {
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
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Edit game title")

                Spacer(minLength: 0)
            }
            .padding(.leading, Spacing._2xl + insets.leading)
            .padding(.trailing, Spacing._2xl + insets.trailing)
            .padding(.bottom, Spacing._2xl)
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

    private func removeCustomImage(pathGetter: (GameMetadata) -> String?,
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
        removeCustomImage(pathGetter: { $0.customArtworkPath(for: game.id) },
                         filenameGetter: { $0.customArtworkFilename },
                         filenameSetter: { $0.customArtworkFilename = $1 })
    }

    private func saveBanner(_ image: UIImage) {
        saveCustomImage(image, kind: "banner",
                       pathGetter: { $0.customBannerPath(for: game.id) },
                       filenameSetter: { $0.customBannerFilename = $1 })
    }

    private func removeBanner() {
        removeCustomImage(pathGetter: { $0.customBannerPath(for: game.id) },
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
        let historyLog = AppState.logsDirectory.appendingPathComponent("session-history.log")
        return FileManager.default.fileExists(atPath: historyLog.path) ? historyLog : nil
    }
}

private struct GroupedSection<Content: View>: View {
    let header: String?
    @ViewBuilder let content: Content

    init(_ header: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header)
                    .font(.body.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing._2xl + Spacing.xl)
                    .padding(.bottom, Spacing.md)
            }

            VStack(spacing: 0) {
                content
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
            .padding(.horizontal, Spacing._2xl)
        }
        .padding(.top, Spacing._2xl)
    }
}

private struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let value: Content

    init(_ label: String, @ViewBuilder value: () -> Content) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            value
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }
}
