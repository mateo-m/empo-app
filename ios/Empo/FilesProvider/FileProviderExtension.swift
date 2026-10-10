import FileProvider
import UniformTypeIdentifiers

/// Shows the games and saves in the Files app, under Locations. They
/// live in the app group, because the game process cannot open the
/// app's Documents, and the Files app shows only an app's Documents.
///
/// The files are real files in `documentStorageURL`, so the Files app
/// opens them where they are, and nothing downloads. An item's
/// identifier is its file ID, which stays the same after a rename or a
/// move. A save that writes a new file and renames it over the old one
/// gives a new file ID.
///
/// A deleted item goes to `.Trash/<id>/<name>`, which the Files app
/// shows in Recently Deleted. The file `.Trash/<id>/.from` holds the
/// identifier of the folder it came from.
final class FileProviderExtension: NSFileProviderExtension {
    private let root = NSFileProviderManager.default.documentStorageURL.resolvingSymlinksInPath()
    private var trash: URL { root.appendingPathComponent(FileProviderItem.trashFolderName) }

    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        let url = identifier == .rootContainer ? root : try existingURL(of: identifier)
        return FileProviderItem(url: url, root: root)
    }

    // Files on iOS 27 greys out Recover for a deleted item that has a
    // URL: it then treats the item as a file in a normal folder.
    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        FileProviderItem.url(of: identifier, root: root).flatMap {
            FileProviderItem.isDeleted($0, root: root) ? nil : $0
        }
    }

    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        FileProviderItem.identifier(of: url, root: root)
    }

    override func providePlaceholder(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let identifier = persistentIdentifierForItem(at: url) else {
                throw NSFileProviderError(.noSuchItem)
            }
            try NSFileProviderManager.writePlaceholder(
                at: NSFileProviderManager.placeholderURL(for: url), withMetadata: item(for: identifier))
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    override func startProvidingItem(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(
            FileManager.default.fileExists(atPath: url.path) ? nil : NSFileProviderError(.noSuchItem))
    }

    // The base class removes nothing, and the file must stay: it is
    // the only copy.
    override func stopProvidingItem(at url: URL) {}

    override func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier
    ) throws
        -> NSFileProviderEnumerator
    {
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer {
            removeOldTrash()
            return FileProviderEnumerator(container: containerItemIdentifier, folder: nil, root: root)
        }
        var isFolder: ObjCBool = false
        guard let url = urlForItem(withPersistentIdentifier: containerItemIdentifier),
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue
        else { throw NSFileProviderError(.noSuchItem) }
        return FileProviderEnumerator(container: containerItemIdentifier, folder: url, root: root)
    }

    override func createDirectory(
        withName directoryName: String,
        inParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.newURL(named: directoryName, in: parentItemIdentifier)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
    }

    override func importDocument(
        at fileURL: URL, toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.newURL(named: fileURL.lastPathComponent, in: parentItemIdentifier)
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: fileURL, to: url)
            return url
        }
    }

    override func renameItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier, toName itemName: String,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.existingURL(of: itemIdentifier)
            let destination = try self.child(named: itemName, of: url.deletingLastPathComponent())
            return try self.move(url, to: destination)
        }
    }

    override func reparentItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        toParentItemWithIdentifier parentItemIdentifier: NSFileProviderItemIdentifier, newName: String?,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.existingURL(of: itemIdentifier)
            let destination = try self.newURL(
                named: newName ?? url.lastPathComponent, in: parentItemIdentifier)
            return try self.move(url, to: destination)
        }
    }

    override func trashItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.existingURL(of: itemIdentifier)
            let folder = self.trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let parent = FileProviderItem.identifier(of: url.deletingLastPathComponent(), root: self.root)
            try Data((parent ?? .rootContainer).rawValue.utf8).write(
                to: folder.appendingPathComponent(".from"))
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            self.trashChanged()
            return destination
        }
    }

    override func untrashItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        toParentItemIdentifier parentItemIdentifier: NSFileProviderItemIdentifier?,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) {
        perform(completionHandler) {
            let url = try self.existingURL(of: itemIdentifier)
            let folder = url.deletingLastPathComponent()
            let destination =
                try parentItemIdentifier.map {
                    try self.newURL(named: url.lastPathComponent, in: $0)
                }
                ?? self.child(
                    named: url.lastPathComponent,
                    of: FileProviderItem.originalFolder(ofDeleted: url, root: self.root))
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw NSFileProviderError(.filenameCollision)
            }
            try FileManager.default.moveItem(at: url, to: destination)
            try? FileManager.default.removeItem(at: folder)
            self.trashChanged()
            return destination
        }
    }

    override func deleteItem(
        withIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            let url = try existingURL(of: itemIdentifier)
            let trashed = FileProviderItem.isDeleted(url, root: root)
            try FileManager.default.removeItem(at: trashed ? url.deletingLastPathComponent() : url)
            if trashed { trashChanged() }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private func perform(
        _ completionHandler: (NSFileProviderItem?, Error?) -> Void, _ change: () throws -> URL
    ) {
        do {
            completionHandler(FileProviderItem(url: try change(), root: root), nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    /// Deletes what has been in the trash for 30 days, as the Files
    /// app does with its own Recently Deleted.
    private func removeOldTrash() {
        let limit = Date().addingTimeInterval(-30 * 24 * 3600)
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: trash, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate,
                created < limit
            else { continue }
            try? FileManager.default.removeItem(at: folder)
            trashChanged()
        }
    }

    // The system keeps its own list of the working set, which holds the
    // trash, and asks for changes only after a signal. Without one,
    // Recently Deleted still shows an item that is gone.
    private func trashChanged() {
        NSFileProviderManager.default.signalEnumerator(for: .workingSet) { _ in }
    }

    private func existingURL(of identifier: NSFileProviderItemIdentifier) throws -> URL {
        guard identifier != .rootContainer, let url = FileProviderItem.url(of: identifier, root: root),
            FileManager.default.fileExists(atPath: url.path)
        else { throw NSFileProviderError(.noSuchItem) }
        return url
    }

    private func newURL(named name: String, in parent: NSFileProviderItemIdentifier) throws -> URL {
        guard let folder = urlForItem(withPersistentIdentifier: parent) else {
            throw NSFileProviderError(.noSuchItem)
        }
        let url = try child(named: name, of: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSFileProviderError(.filenameCollision)
        }
        return url
    }

    private func child(named name: String, of folder: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // A folder can be a link to a folder outside the root.
        let url = folder.appendingPathComponent(name)
        guard FileProviderItem.relativePath(of: url, root: root) != nil else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return url
    }

    private func move(_ url: URL, to destination: URL) throws -> URL {
        // A rename that only changes the case names the same file on
        // a case-insensitive volume.
        if destination.path.lowercased() != url.path.lowercased(),
            FileManager.default.fileExists(atPath: destination.path)
        {
            throw NSFileProviderError(.filenameCollision)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let childItemCount: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let isTrashed: Bool

    static let trashFolderName = ".Trash"

    var capabilities: NSFileProviderItemCapabilities {
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting,
            .allowsTrashing,
        ]
        if contentType == .folder {
            capabilities.insert(.allowsAddingSubItems)
        }
        return capabilities
    }

    init(url: URL, root: URL) {
        itemIdentifier = Self.identifier(of: url, root: root) ?? .rootContainer
        // The system wants the flag on the deleted item only, not on
        // the items inside it.
        isTrashed = Self.isDeleted(url, root: root)
        parentItemIdentifier =
            isTrashed
            ? .trashContainer
            : itemIdentifier == .rootContainer
                ? .rootContainer
                : Self.identifier(of: url.deletingLastPathComponent(), root: root) ?? .rootContainer
        filename = url.lastPathComponent
        // The system refuses .contentTypeKey (error -54) for a file that
        // Files pasted here, and one refused key fails the whole request.
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let isFolder = values?.isDirectory ?? false
        contentType = isFolder ? .folder : UTType(filenameExtension: url.pathExtension) ?? .data
        documentSize = isFolder ? nil : values?.fileSize.map { NSNumber(value: $0) }
        childItemCount =
            isFolder
            ? (try? FileManager.default.contentsOfDirectory(atPath: url.path)).map {
                NSNumber(value: $0.count)
            } : nil
        creationDate = values?.creationDate
        contentModificationDate = values?.contentModificationDate
    }

    static func identifier(of url: URL, root: URL) -> NSFileProviderItemIdentifier? {
        guard let path = relativePath(of: url, root: root) else { return nil }
        if path.isEmpty { return .rootContainer }
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return nil }
        return NSFileProviderItemIdentifier(String(info.st_ino))
    }

    static func url(of identifier: NSFileProviderItemIdentifier, root: URL) -> URL? {
        if identifier == .rootContainer { return root }
        guard let fileID = UInt64(identifier.rawValue), let rootPath = realpath(root.path, nil) else {
            return nil
        }
        defer { free(rootPath) }
        var volume = statfs()
        guard statfs(rootPath, &volume) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&buffer, buffer.count, &volume.f_fsid, fileID) > 0 else { return nil }
        // fsgetpath gives the real path, with /private, which
        // resolvingSymlinksInPath removes from `root`.
        guard
            let path = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        else { return nil }
        let prefix = String(cString: rootPath) + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return root.appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    /// True for `.Trash/<id>/<name>`, the item that the user deleted,
    /// and false for the items inside it.
    static func isDeleted(_ url: URL, root: URL) -> Bool {
        guard let path = relativePath(of: url, root: root) else { return false }
        return path.hasPrefix(trashFolderName + "/") && path.split(separator: "/").count == 3
    }

    /// The folder that a deleted item came from, or `root` when that
    /// folder is gone or deleted too.
    static func originalFolder(ofDeleted url: URL, root: URL) -> URL {
        (try? String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent(".from"), encoding: .utf8))
            .flatMap { Self.url(of: NSFileProviderItemIdentifier($0), root: root) }
            .flatMap {
                relativePath(of: $0, root: root)?.hasPrefix(trashFolderName + "/") == false ? $0 : nil
            }
            ?? root
    }

    /// The path of `url` relative to `root`: empty for `root`, and nil
    /// when `url` is not inside it.
    static func relativePath(of url: URL, root: URL) -> String? {
        // The item itself can be a link, which is its own item.
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
        if path == root.path { return "" }
        guard path.hasPrefix(root.path + "/") else { return nil }
        return String(path.dropFirst(root.path.count + 1))
    }
}

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    /// Nil for the working set and the trash. The working set holds
    /// only the trashed items, which the Files app shows in Recently
    /// Deleted.
    private let folder: URL?
    private let root: URL

    init(container: NSFileProviderItemIdentifier, folder: URL?, root: URL) {
        self.container = container
        self.folder = folder
        self.root = root
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage)
    {
        let items = currentItems()
        observer.didEnumerate(items)
        saveListed(items)
        observer.finishEnumerating(upTo: nil)
    }

    // The app changes the folder too, and keeps no record of the
    // changes, so this compares the folder with the last list that the
    // system got. The system does not list the folder again after
    // .syncAnchorExpired: it asks for changes again and again.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let items = currentItems()
        let current = Set(items.map(\.itemIdentifier.rawValue))
        let gone = listed().subtracting(current).map { NSFileProviderItemIdentifier($0) }
        if !gone.isEmpty { observer.didDeleteItems(withIdentifiers: gone) }
        observer.didUpdate(items)
        saveListed(items)
        observer.finishEnumeratingChanges(upTo: newAnchor(), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(newAnchor())
    }

    private func newAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(UUID().uuidString.utf8))
    }

    private func currentItems() -> [FileProviderItem] {
        let fm = FileManager.default
        let list = { (url: URL) in
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
                ?? []
        }
        let urls =
            folder.map(list)
            ?? list(root.appendingPathComponent(FileProviderItem.trashFolderName)).flatMap(list)
        // An item that goes away during the list gets the root's identifier.
        return urls.map { FileProviderItem(url: $0, root: root) }
            .filter { $0.itemIdentifier != .rootContainer }
    }

    /// The identifiers that the system got for this container, kept in
    /// the add-on's own Application Support, outside the folder that
    /// Files shows. iOS can empty Caches, and then Files would keep the
    /// items that went away before that.
    private var listedURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = Data(container.rawValue.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        return support.appendingPathComponent("Listed", isDirectory: true).appendingPathComponent(name)
    }

    private func listed() -> Set<String> {
        guard let data = try? Data(contentsOf: listedURL),
            let identifiers = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(identifiers)
    }

    private func saveListed(_ items: [FileProviderItem]) {
        let url = listedURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items.map(\.itemIdentifier.rawValue)).write(to: url, options: .atomic)
    }
}
