import Foundation

/// Why a package is refused, per SPEC 12.6.
///
/// Every case stops the restore before it writes user data. A
/// package is the one input in this feature that a stranger
/// produced, so it gets checked like one.
public enum PackageRejection: Error, Equatable, Sendable {
    case noManifest
    case unreadableManifest
    /// A newer Empo wrote it, per 15.5.
    case futureVersion(Int)
    case absolutePath(String)
    case parentTraversal(String)
    case link(String)
    /// A file in the ZIP that the manifest does not name.
    case undeclaredFile(String)
    /// A file the manifest names that the ZIP does not hold.
    case missingFile(String)
    case duplicatePath(String)
    case wrongSize(String)
    case wrongHash(String)

    /// The line the import sheet shows. It names the fault and the
    /// path, because the user can only act on a package Empo names.
    public var line: String {
        switch self {
        case .noManifest:
            return "This ZIP file is not an Empo backup package."
        case .unreadableManifest:
            return "The package list of files does not read."
        case .futureVersion(let version):
            return "A newer Empo wrote this package, version \(version). Update Empo to open it."
        case .absolutePath(let path):
            return "The package holds a full path: \(path)."
        case .parentTraversal(let path):
            return "The package points outside itself: \(path)."
        case .link(let path):
            return "The package holds a link: \(path)."
        case .undeclaredFile(let path):
            return "The package holds a file its list does not name: \(path)."
        case .missingFile(let path):
            return "The package list names a file the package does not hold: \(path)."
        case .duplicatePath(let path):
            return "The package names one path twice: \(path)."
        case .wrongSize(let path):
            return "A file is not the size the package states: \(path)."
        case .wrongHash(let path):
            return "A file does not match the package hash: \(path)."
        }
    }
}

/// The checks an import runs before any write, per SPEC 12.6.
public enum PackageValidation {

    /// The two files every package carries beside the data.
    static let ownFiles: Set<String> = [PackageLayout.manifestPath, PackageLayout.readmePath]

    /// Reads the manifest of a package, or says why it is not one.
    public static func manifest(ofZip entries: [ZipEntry], data: Data?) throws -> PackageManifest {
        guard entries.contains(where: { $0.path == PackageLayout.manifestPath }),
            let data
        else {
            throw PackageRejection.noManifest
        }
        guard let manifest = try? PackageManifest.decode(json: data) else {
            throw PackageRejection.unreadableManifest
        }
        guard manifest.packageVersion <= PackageManifest.currentVersion else {
            throw PackageRejection.futureVersion(manifest.packageVersion)
        }
        return manifest
    }

    /// Checks the manifest against what the ZIP holds.
    ///
    /// The order is the order a failure costs least: the paths
    /// first, because a bad path never has to be read, then the
    /// links, then what the two sides do not agree on.
    public static func check(_ manifest: PackageManifest, against entries: [ZipEntry]) throws {
        var declared: Set<String> = []
        for file in manifest.files {
            try checkThePath(file.zipPath)
            try checkThePath(file.entry.path)
            guard declared.insert(file.zipPath).inserted else {
                throw PackageRejection.duplicatePath(file.zipPath)
            }
        }

        var seen: Set<String> = []
        for entry in entries where !entry.isDirectory {
            if entry.isSymbolicLink { throw PackageRejection.link(entry.path) }
            try checkThePath(entry.path)
            guard seen.insert(entry.path).inserted else {
                throw PackageRejection.duplicatePath(entry.path)
            }
            guard declared.contains(entry.path) || ownFiles.contains(entry.path) else {
                throw PackageRejection.undeclaredFile(entry.path)
            }
        }

        let sizes = Dictionary(
            entries.map { ($0.path, $0.uncompressedSize) }, uniquingKeysWith: { first, _ in first })
        for file in manifest.files {
            guard let size = sizes[file.zipPath] else {
                throw PackageRejection.missingFile(file.zipPath)
            }
            guard size == file.entry.size else {
                throw PackageRejection.wrongSize(file.zipPath)
            }
        }
    }

    /// A path stays inside the package: no root, no drive, no
    /// parent step, and no backslash that a reader on another
    /// system would take for a separator.
    public static func checkThePath(_ path: String) throws {
        guard !path.hasPrefix("/") else { throw PackageRejection.absolutePath(path) }
        guard !path.contains("\\"), path.count < 2 || path[path.index(path.startIndex, offsetBy: 1)] != ":"
        else {
            throw PackageRejection.absolutePath(path)
        }
        for part in path.split(separator: "/") where part == ".." {
            throw PackageRejection.parentTraversal(path)
        }
    }

    /// The hash check of 12.6, which runs as each file stages.
    public static func checkTheContent(
        of file: PackageFile, stagedSize: Int64, stagedHash: String
    ) throws {
        guard stagedSize == file.entry.size else {
            throw PackageRejection.wrongSize(file.zipPath)
        }
        guard stagedHash == file.entry.hash else {
            throw PackageRejection.wrongHash(file.zipPath)
        }
    }
}
