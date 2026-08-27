import Foundation

/// What the resolver needs to answer "which files are in this game's
/// backup set right now", per SPEC 3.
///
/// Every path in this request is relative to the game's container and
/// uses `/` as the separator.
public struct GameBackupSetRequest: Sendable {

    /// `Documents/Games/<folderName>/`.
    public var containerURL: URL
    public var mode: BackupMode
    /// The shared data directory the game resolved to, per 4.5.
    public var sharedDataDirectory: URL?
    /// `Documents/`, so the header records the shared path the way
    /// 4.5 wants it: relative to `Documents/`, because the absolute
    /// path holds an app-container id no second device can rebuild.
    /// Without it the header falls back to the absolute path.
    public var documentsRoot: URL?
    /// The Rescued Saves buckets that match this game, per 4.5,
    /// keyed by bucket name.
    public var rescuedSavesBuckets: [String: URL]
    /// The marks of 3.6, from `EmpoState/backup.json`.
    public var manualMarks: [String]
    /// The paths the runtime watch joined, per 3.6.
    ///
    /// A join has no store of its own. The manifest records the
    /// label per entry, per 3.6, so the last manifest carries the
    /// joins of every earlier session, and the live session adds
    /// what it saw. That keeps 6.3 true: the cache is never truth.
    public var runtimeWatchPaths: [String]

    public init(
        containerURL: URL,
        mode: BackupMode,
        sharedDataDirectory: URL? = nil,
        documentsRoot: URL? = nil,
        rescuedSavesBuckets: [String: URL] = [:],
        manualMarks: [String] = [],
        runtimeWatchPaths: [String] = []
    ) {
        self.containerURL = containerURL
        self.mode = mode
        self.sharedDataDirectory = sharedDataDirectory
        self.documentsRoot = documentsRoot
        self.rescuedSavesBuckets = rescuedSavesBuckets
        self.manualMarks = manualMarks
        self.runtimeWatchPaths = runtimeWatchPaths
    }
}

/// What the library-wide stream of SPEC 5.3 needs. It belongs to no
/// game, so it has its own request.
public struct LibraryBackupSetRequest: Sendable {

    /// `Documents/Profiles/`, the layout profiles of 3.1.
    public var profilesDirectory: URL?
    /// The UserDefaults export of 3.1. Section 10 fixes which keys
    /// are portable, and ticket 015 writes the file. The resolver
    /// only puts the file that is there into the stream.
    public var userDefaultsExportFile: URL?
    /// The Rescued Saves buckets that match no installed game, per
    /// 3.1 and 4.5, keyed by bucket name.
    public var rescuedSavesBuckets: [String: URL]

    public init(
        profilesDirectory: URL? = nil,
        userDefaultsExportFile: URL? = nil,
        rescuedSavesBuckets: [String: URL] = [:]
    ) {
        self.profilesDirectory = profilesDirectory
        self.userDefaultsExportFile = userDefaultsExportFile
        self.rescuedSavesBuckets = rescuedSavesBuckets
    }
}

/// Which files are in a game's backup set right now, per SPEC 3.
///
/// The resolver reads the filesystem and decides nothing else. It
/// never writes, and it never deletes: the classifier decides no
/// delete, per invariant 3, and ticket 014 owns the restore rules.
public enum BackupSetResolver {

    /// The path a member of the library stream carries under the
    /// layout profiles.
    public static let profilesPathPrefix = "profiles"
    /// The path a member of the library stream carries under a
    /// Rescued Saves bucket.
    public static let rescuedSavesPathPrefix = "rescued-saves"
    /// The name the UserDefaults export takes in the stream.
    public static let userDefaultsExportPathName = "userdefaults.json"

    // MARK: - One game

    public static func resolve(
        _ request: GameBackupSetRequest, fm: FileManager = .default
    ) -> GameBackupSet {
        var members = containerMembers(request, fm: fm)

        if let shared = request.sharedDataDirectory {
            members += files(under: shared, fm: fm).map {
                BackupSetMember(
                    root: .sharedData,
                    path: $0.path,
                    size: $0.size,
                    modifiedAt: $0.modifiedAt)
            }
        }

        for name in request.rescuedSavesBuckets.keys.sorted() {
            guard let bucket = request.rescuedSavesBuckets[name],
                !RescuedSaves.isExcludedFromBackup(bucket: bucket, fm: fm)
            else { continue }
            members += files(under: bucket, fm: fm).map {
                BackupSetMember(
                    root: .rescuedSaves,
                    path: "\(name)/\($0.path)",
                    size: $0.size,
                    modifiedAt: $0.modifiedAt)
            }
        }

        return GameBackupSet(
            mode: request.mode,
            members: sorted(members),
            sharedDataDirectory: recordedSharedPath(request),
            rescuedSavesBuckets: request.rescuedSavesBuckets.keys.sorted())
    }

    /// The stream that belongs to no game, per 5.3.
    public static func resolveLibraryStream(
        _ request: LibraryBackupSetRequest, fm: FileManager = .default
    ) -> GameBackupSet {
        var members: [BackupSetMember] = []

        if let profiles = request.profilesDirectory {
            members += files(under: profiles, fm: fm)
                .filter { !BackupSetRules.carriesDisplacedMarker($0.path) }
                .map {
                    BackupSetMember(
                        root: .preferences,
                        path: "\(profilesPathPrefix)/\($0.path)",
                        size: $0.size,
                        modifiedAt: $0.modifiedAt)
                }
        }

        if let export = request.userDefaultsExportFile, let stamp = stamp(of: export, fm: fm) {
            members.append(
                BackupSetMember(
                    root: .preferences,
                    path: userDefaultsExportPathName,
                    size: stamp.size,
                    modifiedAt: stamp.modifiedAt))
        }

        for name in request.rescuedSavesBuckets.keys.sorted() {
            guard let bucket = request.rescuedSavesBuckets[name],
                !RescuedSaves.isExcludedFromBackup(bucket: bucket, fm: fm)
            else { continue }
            members += files(under: bucket, fm: fm).map {
                BackupSetMember(
                    root: .preferences,
                    path: "\(rescuedSavesPathPrefix)/\(name)/\($0.path)",
                    size: $0.size,
                    modifiedAt: $0.modifiedAt)
            }
        }

        return GameBackupSet(mode: .slim, members: sorted(members))
    }

    /// The shared data directory as the manifest header records it,
    /// per 4.5.
    private static func recordedSharedPath(_ request: GameBackupSetRequest) -> String? {
        guard let shared = request.sharedDataDirectory else { return nil }
        guard let documents = request.documentsRoot else { return shared.path }
        return ExternalMembers.recordedPath(of: shared, documentsRoot: documents)
    }

    // MARK: - The container

    private static func containerMembers(
        _ request: GameBackupSetRequest, fm: FileManager = .default
    ) -> [BackupSetMember] {
        let classifierPaths = classifierMatches(containerURL: request.containerURL, fm: fm)

        return files(under: request.containerURL, fm: fm).compactMap { file in
            guard !BackupSetRules.isAlwaysOut(containerRelativePath: file.path) else {
                return nil
            }
            let source = detectionSource(
                of: file.path,
                classifierPaths: classifierPaths,
                request: request)

            if request.mode == .full {
                // The whole tree, per 3.3. The label still rides
                // along where a source found the file, because 7.2
                // reads it to tell a partial save from a partial
                // log.
                return BackupSetMember(
                    root: .container,
                    path: file.path,
                    size: file.size,
                    modifiedAt: file.modifiedAt,
                    detectionSource: source)
            }

            // Slim mode, per 3.4: the sources, the marks, and the
            // always-in list of 3.1.
            guard source != nil
                || BackupSetRules.isAlwaysIn(containerRelativePath: file.path)
            else { return nil }
            return BackupSetMember(
                root: .container,
                path: file.path,
                size: file.size,
                modifiedAt: file.modifiedAt,
                detectionSource: source)
        }
    }

    /// Which source found a path, per 3.6.
    ///
    /// A path may carry more than one signal. A mark wins, because
    /// the user said so out loud, and a watched write beats a
    /// classifier guess for the same reason. The three labels are
    /// equal to 7.2, which asks only whether the entry is a save
    /// member, so the order is about what the UI shows.
    private static func detectionSource(
        of path: String, classifierPaths: Set<String>, request: GameBackupSetRequest
    ) -> DetectionSource? {
        if BackupSetRules.marks(request.manualMarks, cover: path) { return .manualMark }
        if BackupSetRules.marks(request.runtimeWatchPaths, cover: path) { return .runtimeWatch }
        if classifierPaths.contains(path) { return .classifier }
        return nil
    }

    /// The container-relative paths the classifier matches.
    ///
    /// `PortableGameSaves` names the entries at the game root, a
    /// mix of files and directories, so a directory expands into its
    /// files here.
    public static func classifierMatches(
        containerURL: URL, fm: FileManager = .default
    ) -> Set<String> {
        let gameRoot = containerURL.appendingPathComponent(
            BackupSetRules.gameDirectoryName, isDirectory: true)
        var paths: Set<String> = []

        for name in PortableGameSaves.entryNames(atGameRoot: gameRoot, fm: fm) {
            let url = gameRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let prefix = "\(BackupSetRules.gameDirectoryName)/\(name)"
            if isDirectory.boolValue {
                for file in files(under: url, fm: fm) {
                    paths.insert("\(prefix)/\(file.path)")
                }
            } else {
                paths.insert(prefix)
            }
        }
        return paths
    }

    // MARK: - The walk

    /// One file the walk found, with its path relative to the root
    /// the walk started from.
    public struct WalkedFile: Equatable, Sendable {
        public var path: String
        public var size: Int64
        public var modifiedAt: Date

        public init(path: String, size: Int64, modifiedAt: Date) {
            self.path = path
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    /// Every regular file under `root`, sorted by path.
    ///
    /// Symbolic links are skipped. A link out of the tree would put
    /// a file in the set under a path a restore cannot rebuild, and
    /// a link inside the tree would upload its target twice.
    public static func files(under root: URL, fm: FileManager = .default) -> [WalkedFile] {
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [])
        else { return [] }

        let base = root.standardizedFileURL.path
        var out: [WalkedFile] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            guard let stamp = stamp(of: url, fm: fm) else { continue }
            guard let relative = relativePath(of: url, underBase: base) else { continue }
            out.append(WalkedFile(path: relative, size: stamp.size, modifiedAt: stamp.modifiedAt))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// The size and the modified time of a regular file, or `nil`
    /// when the URL is not one.
    public static func stamp(of url: URL, fm: FileManager = .default) -> FileStamp? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                .contentModificationDateKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else { return nil }
        return FileStamp(
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0))
    }

    private static func relativePath(of url: URL, underBase base: String) -> String? {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return nil }
        return String(full.dropFirst(base.count + 1))
    }

    private static func sorted(_ members: [BackupSetMember]) -> [BackupSetMember] {
        members.sorted {
            $0.root == $1.root ? $0.path < $1.path : $0.root.rawValue < $1.root.rawValue
        }
    }
}
