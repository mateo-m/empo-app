import GameProbe
import SwiftUI

struct GameInfoView: View {
    let game: GameEntry
    @Environment(\.gameLibrary) private var library
    @Environment(\.hintStore) private var hintStore
    @Environment(\.appSettings) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var metadata: GameMetadata
    @State private var editingTitle: String
    @State private var diskSize: Int64?
    @State private var rgssVersion: Int?
    @State private var rubyVersion: String?
    @State private var runtimeProbeFinished = false
    @State private var showArtworkPicker = false
    @State private var showBannerPicker = false
    @State private var isEditingTitle = false
    @State private var titleScrollProgress: CGFloat = 0
    @State private var navBarBottomY: CGFloat = 0
    @State private var needsLibraryRefresh = false
    /// Bumped whenever a custom image is saved or removed. Custom
    /// media lives at fixed filenames ("artwork.jpg"/"banner.jpg"),
    /// so a replacement leaves every path unchanged; this token is
    /// the signal that makes image-loading tasks refire anyway.
    @State private var customImageRefreshToken = 0
    @FocusState private var isTitleFocused: Bool

    private let originalTitle: String

    init(game: GameEntry) {
        self.game = game
        // GameInfoView is only shown for ready entries that have a
        // committed container on disk.
        let container = game.container!
        let meta = GameMetadata.load(from: container)
        _metadata = State(initialValue: meta)
        _editingTitle = State(initialValue: meta.customTitle ?? "")

        // Title shown when the user hasn't set a customTitle. For
        // JGP imports this is the manifest name. For plain
        // folder/zip imports it's the Game.ini title. The label
        // under the text field (and the text-field placeholder)
        // both track this so resetting the custom title gives the
        // user back what the import originally showed, not the
        // raw Game.ini one which may be uglier.
        self.originalTitle =
            meta.baseTitle
            ?? GameINI.parseINIValue(at: container.gameURL, section: "game", key: "title")
            ?? "Unknown Game"
    }

    private var container: GameContainer? { game.container }

    /// Decoded off-main via the banner `.task` below. Keyed on the
    /// banner filename plus `customImageRefreshToken` so both a
    /// newly-set banner and an in-place replacement (the filename is
    /// the fixed "banner.jpg") reload it.
    @State private var bannerImage: UIImage?

    private var bannerTaskID: String {
        "\(metadata.customBannerFilename ?? "none")|\(customImageRefreshToken)"
    }

    /// Path to the artwork to render: user-set custom override
    /// first, then whatever the import pipeline resolved into
    /// `game.artworkPath` (extracted exec icon -> Graphics/Titles
    /// -> nil). Other library surfaces honor the same chain.
    /// Centralized here so `bannerBackground` and `artworkView`
    /// agree without duplicating the branch.
    private var resolvedArtworkPath: String? {
        guard let container else { return game.artworkPath }
        return metadata.customArtworkPath(in: container) ?? game.artworkPath
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

                        if hintStore.isVisible(.gameInfoCustomization) {
                            HintBanner(hint: .gameInfoCustomization)
                                .padding(.horizontal, Spacing._2xl)
                                .padding(.top, Spacing.xl)
                                .transition(.hintBanner)
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
                                    Text(
                                        Self.relativeDateFormatter.localizedString(
                                            for: date, relativeTo: Date()))
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

                        // Runtime diagnostics. Surfaces the engine
                        // graphics-API version and the bundled-Ruby
                        // version (when present) so an advanced user
                        // can confirm what compatibility surface a
                        // game ships with. Useful for debugging
                        // syntax-transform misdetections (a custom
                        // engine shipping RGSS1 graphics + Ruby 3.x
                        // vs vanilla XP shipping RGSS1 + Ruby 1.8).
                        // Gated on debugLogs because casual users
                        // shouldn't see internal API version numbers.
                        if settings.debugLogs {
                            GroupedSection("Runtime") {
                                DetailRow("RGSS version") {
                                    if let v = rgssVersion {
                                        Text("RGSS\(v)")
                                    } else if runtimeProbeFinished {
                                        Text("Unknown")
                                    } else {
                                        ProgressView()
                                    }
                                }

                                Divider().padding(.leading, Spacing.xl)

                                // Ruby (bundled): the version the game's
                                // own DLL targets (e.g. Pokemon Flux's
                                // x64-msvcrt-ruby310.dll). On iOS we
                                // execute on the statically-linked engine
                                // Ruby below. This row only says what the
                                // scripts were written for.
                                if let v = rubyVersion {
                                    DetailRow("Ruby (bundled)") {
                                        Text(v).monospaced()
                                    }

                                    Divider().padding(.leading, Spacing.xl)
                                }

                                // Ruby (runtime): the version executing
                                // the scripts on iOS, scanned from Empo's
                                // binary. For games with a bundled DLL
                                // this row makes the gap explicit
                                // (e.g. "3.1.0p0 bundled vs 3.1.3p185
                                // runtime").
                                DetailRow("Ruby (runtime)") {
                                    if !runtimeProbeFinished {
                                        ProgressView()
                                    } else {
                                        // Pass the game's detected RGSS-derived
                                        // Ruby major.minor so multi-Ruby binaries
                                        // (which contain up to 4 RUBY_DESCRIPTION
                                        // strings, one per merged.o) report the
                                        // version that'll actually run THIS game,
                                        // not whichever string sits earliest in
                                        // the .rodata section.
                                        let majorMinor = rubyMajorMinorForGame()
                                        if let engine = GameMetadata.engineRubyVersion(
                                            forMajorMinor: majorMinor
                                        ) {
                                            Text(engine).monospaced()
                                        } else {
                                            Text("Unknown")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        GroupedSection {
                            Button {
                                openInFiles()
                            } label: {
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
                    .sheetTitle()
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
            .onAppear {
                if let container {
                    metadata = GameMetadata.load(from: container)
                }
            }
            .task(id: bannerTaskID) {
                guard let container,
                    let path = metadata.customBannerPath(in: container)
                else {
                    bannerImage = nil
                    return
                }
                // thumbnail() awaits a detached task that survives
                // task cancellation. Without the guard, a cancelled
                // run resumes late and overwrites the newer task's
                // result - removing a banner could resurrect it.
                let image = await ImageCache.shared.thumbnail(
                    for: path, maxPixelSize: ImageCache.PixelBudget.hero)
                if Task.isCancelled { return }
                bannerImage = image
            }
            .task {
                if let container {
                    // Disk size of the entire container (Game/ +
                    // EmpoState/ + Logs/ + Metadata/). This is what
                    // users expect to see when they ask "how big is
                    // this game on my device". Game/ dominates by far
                    // (tens of MB to GB), so the rest is rounding.
                    diskSize = await GameMetadata.diskSize(for: container.url)
                }
            }
            .task {
                // Runtime probe: scan game folder for RGSS version
                // and bundled Ruby version. Off-main-thread because
                // the Ruby scan opens DLLs (5-15 MB each, a few in
                // a typical PE-derived game) and runs an
                // NSRegularExpression over the ASCII-decoded bytes.
                guard let container, settings.debugLogs else {
                    runtimeProbeFinished = true
                    return
                }
                let gameURL = container.gameURL
                let result: (Int?, String?) = await Task.detached(priority: .utility) {
                    (
                        GameMetadata.detectRGSSVersion(in: gameURL),
                        GameMetadata.detectBundledRubyVersion(in: gameURL)
                    )
                }.value
                rgssVersion = result.0
                rubyVersion = result.1
                runtimeProbeFinished = true
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

    /// Map the game's detected/overridden Ruby version code
    /// (18 / 19 / 30 / 31, persisted as `metadata.rubyVersion` or
    /// `GameSettings.rubyVersionOverride`) to the corresponding
    /// "<major>.<minor>" string the binary scanner expects. Falls
    /// back to deriving from `rgssVersion` (RGSS1/2 → 1.8, RGSS3
    /// → 1.9) when the explicit Ruby field hasn't been set yet
    /// (e.g. games imported before multi-Ruby detection rolled
    /// out, or before the library backfill task ran).
    /// Returns nil when no signal is available. The caller falls
    /// back to a no-filter scan.
    private func rubyMajorMinorForGame() -> String? {
        // Per-game override wins.
        if let container = game.container {
            let settings = GameSettings.load(from: container.empoStateURL)
            if let override = settings.rubyVersionOverride {
                return rubyCodeToMajorMinor(override)
            }
        }
        // Detector's persisted result.
        if let v = metadata.rubyVersion {
            return rubyCodeToMajorMinor(v)
        }
        // Fall back to RGSS-derived if the detector hasn't run yet.
        switch rgssVersion {
        case 1, 2: return "1.8"
        case 3: return "1.9"
        default: return nil
        }
    }

    private func rubyCodeToMajorMinor(_ code: Int) -> String? {
        switch code {
        case 18: return "1.8"
        case 19: return "1.9"
        // 30 may appear in old metadata.json from when a native
        // 3.0 binding shipped. The dispatcher routes 30 to the
        // 3.1 runtime so report 3.1 to match the engine state.
        case 30, 31: return "3.1"
        default: return nil
        }
    }

    private let bannerHeight: CGFloat = 260

    private func bannerHeader(insets: EdgeInsets) -> some View {
        ZStack(alignment: .bottomLeading) {
            bannerBackground
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingTitle { finishEditingTitle() } else { showBannerPicker = true }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Change banner image")
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.4),
                            .init(color: .clear, location: 1.0),
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
                        if isEditingTitle { finishEditingTitle() } else { showArtworkPicker = true }
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
        } else {
            // No banner: fall through to the unified placeholder
            // (gradient + Empo mark). The artwork path
            // used to back-fill here, but the design rule is that
            // banner == loading-view backdrop, just larger / not
            // blurred, so the two surfaces stay visually
            // consistent. Banner-less games show the placeholder
            // here AND on the loading view (where it gets blurred
            // and darkened). Artwork here would produce two
            // different visuals for the same game.
            GameArtworkView(
                artworkPath: nil,
                placeholderIconSize: 64,
                shimmer: false
            )
            .frame(height: bannerHeight)
        }
    }

    /// Foreground artwork tile that floats over the banner. Routed
    /// through `GameArtworkView` so the placeholder matches the
    /// rest of the library (gradient + Empo mark), and
    /// custom artwork picks up the same icon-composite handling
    /// that grid/list cards already use for transparent PE icons.
    private var artworkView: some View {
        GameArtworkView(
            artworkPath: resolvedArtworkPath,
            placeholderIconSize: 32,
            size: AppSize.infoArtwork,
            cornerRadius: Radius.md,
            shimmer: false,
            reloadToken: customImageRefreshToken
        )
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
        guard let container else { return }
        let title = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.customTitle = title.isEmpty ? nil : title
        metadata.save(to: container)
        needsLibraryRefresh = true
    }

    private func saveCustomImage(
        _ image: UIImage, kind: String,
        pathGetter: (GameMetadata, GameContainer) -> String?,
        filenameSetter: (inout GameMetadata, String?) -> Void
    ) {
        guard let container else { return }
        if let path = pathGetter(metadata, container) {
            ImageCache.shared.evict(path: path)
        }
        guard let filename = GameMetadata.saveImage(image, as: kind, in: container) else { return }
        filenameSetter(&metadata, filename)
        metadata.save(to: container)
        if let path = pathGetter(metadata, container) {
            // Second evict, now that the new bytes are on disk: the
            // pre-write evict above can't cover a load that raced
            // the gap and cached the old contents. Then prime the
            // cache so cache-first readers pick up the new image.
            ImageCache.shared.evict(path: path)
            Task.detached(priority: .userInitiated) {
                ImageCache.shared.prewarmThumbnail(
                    for: path, maxPixelSize: ImageCache.PixelBudget.cell)
                ImageCache.shared.prewarmThumbnail(
                    for: path, maxPixelSize: ImageCache.PixelBudget.hero)
            }
        }
        // The media file lives at a fixed name, so a replacement
        // changes no model field and `refreshGameEntry`'s guarded
        // apply() notifies nobody. The revision bump is the explicit
        // signal that refires the card/hero artwork load tasks.
        game.artworkRevision += 1
        customImageRefreshToken += 1
        needsLibraryRefresh = true
    }

    private func removeCustomImage(
        pathGetter: (GameMetadata, GameContainer) -> String?,
        filenameGetter: (GameMetadata) -> String?,
        filenameSetter: (inout GameMetadata, String?) -> Void
    ) {
        guard let container else { return }
        if let path = pathGetter(metadata, container) {
            ImageCache.shared.evict(path: path)
        }
        if let filename = filenameGetter(metadata) {
            GameMetadata.removeImage(named: filename, in: container)
        }
        filenameSetter(&metadata, nil)
        metadata.save(to: container)
        game.artworkRevision += 1
        customImageRefreshToken += 1
        needsLibraryRefresh = true
    }

    private func saveArtwork(_ image: UIImage) {
        saveCustomImage(
            image, kind: "artwork",
            pathGetter: { $0.customArtworkPath(in: $1) },
            filenameSetter: { $0.customArtworkFilename = $1 })
    }

    private func removeArtwork() {
        removeCustomImage(
            pathGetter: { $0.customArtworkPath(in: $1) },
            filenameGetter: { $0.customArtworkFilename },
            filenameSetter: { $0.customArtworkFilename = $1 })
    }

    private func saveBanner(_ image: UIImage) {
        saveCustomImage(
            image, kind: "banner",
            pathGetter: { $0.customBannerPath(in: $1) },
            filenameSetter: { $0.customBannerFilename = $1 })
    }

    private func removeBanner() {
        removeCustomImage(
            pathGetter: { $0.customBannerPath(in: $1) },
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
        guard let container else { return nil }
        let historyLog = container.sessionHistoryURL
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
