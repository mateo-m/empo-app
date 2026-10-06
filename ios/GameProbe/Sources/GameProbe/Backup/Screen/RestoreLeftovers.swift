import Foundation

/// What a restore left behind in one game's container, per SPEC
/// 11.12.
public struct GameLeftovers: Equatable, Sendable {

    /// The replaced game trees, `Game.empo-displaced` and its
    /// numbered repeats.
    public var trees: [URL] = []
    public var treeBytes: Int64 = 0
    /// The single files a restore moved aside.
    public var files: [URL] = []
    public var fileBytes: Int64 = 0
    /// The one warning of 11.12, where a single file passed three
    /// copies.
    public var warning: String?

    public init() {}

    public var isEmpty: Bool { trees.isEmpty && files.isEmpty }
}

/// One destructive confirmation of SPEC 13.15.
public struct LeftoverConfirmation: Equatable, Sendable {

    public var title: String
    public var body: String
    public var buttonLabel: String

    public init(title: String, body: String, buttonLabel: String) {
        self.title = title
        self.body = body
        self.buttonLabel = buttonLabel
    }
}

/// The "Left over from a restore" section of SPEC 13.15 and 11.12.
///
/// One row for the replaced tree with its size, and one row for the
/// displaced copies with a count and a total. Each deletes behind a
/// confirmation that names what goes. There is no "Delete all",
/// because this is data the player may still want.
public enum RestoreLeftovers {

    public static let heading = "Left over from a restore"

    /// `sizeText` carries the size in the words the caller
    /// formatted.
    public static func replacedTreeRow(sizeText: String) -> String {
        "Replaced game files, \(sizeText)"
    }

    public static func displacedCopiesRow(count: Int, sizeText: String) -> String {
        let copies = count == 1 ? "1 replaced file" : "\(count) replaced files"
        return "\(copies), \(sizeText)"
    }

    public static func replacedTreeConfirmation(
        gameName: String, sizeText: String
    ) -> LeftoverConfirmation {
        LeftoverConfirmation(
            title: "Delete the replaced game files?",
            body:
                "A restore moved these files aside. They hold \(sizeText) of the game files "
                + "\(gameName) had before that restore.",
            buttonLabel: "Delete")
    }

    public static func displacedCopiesConfirmation(
        count: Int, sizeText: String
    ) -> LeftoverConfirmation {
        let copies = count == 1 ? "1 file" : "\(count) files"
        return LeftoverConfirmation(
            title: count == 1 ? "Delete 1 replaced file?" : "Delete \(count) replaced files?",
            body:
                "A restore moved \(copies) aside and wrote the backup's files in their place. "
                + "The moved files hold \(sizeText).",
            buttonLabel: count == 1 ? "Delete 1 file" : "Delete \(count) files")
    }

    /// Every name inside one container that carries the displaced
    /// marker of 3.2. A marked directory counts once, so the files
    /// under a replaced tree never count twice.
    public static func inside(_ container: URL) -> GameLeftovers {
        let fm = FileManager.default
        var found = GameLeftovers()
        var copiesByOriginal: [String: Int] = [:]
        var queue = [container]

        while let directory = queue.popLast() {
            let entries =
                (try? fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for url in entries {
                let name = url.lastPathComponent
                let isDirectory =
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard BackupSetRules.carriesDisplacedMarker(name) else {
                    if isDirectory { queue.append(url) }
                    continue
                }
                if let original = DisplacedCopy.originalName(ofDisplaced: name) {
                    copiesByOriginal[original, default: 0] += 1
                }
                if isDirectory {
                    found.trees.append(url)
                    found.treeBytes += size(of: url)
                } else {
                    found.files.append(url)
                    found.fileBytes += size(of: url)
                }
            }
        }

        if let (name, count) = copiesByOriginal.max(by: { $0.value < $1.value }) {
            found.warning = copyWarning(fileName: name, count: count)
        }
        return found
    }

    private static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.fileSize ?? 0) }
        return BackupSetResolver.files(under: url).reduce(0) { $0 + $1.size }
    }

    /// The one warning of 11.12. Empo warns once when a single file
    /// passes three copies, because dropping the oldest copy by
    /// itself would be a silent delete of user data.
    public static func copyWarning(fileName: String, count: Int) -> String? {
        guard count > DisplacedCopy.copyWarningCount else { return nil }
        return "\(fileName) now has \(count) replaced copies on this device."
    }
}
