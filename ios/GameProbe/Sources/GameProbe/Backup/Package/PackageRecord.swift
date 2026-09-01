import Foundation

/// Which way a staged package got there.
public enum PackageKind: String, Codable, Sendable {
    /// Empo built it for an export, per 12.5.
    case built
    /// The user picked it for an import, per 12.6.
    case imported
}

/// One package in the staging area, per SPEC 12.5 and 12.6.
///
/// A completed ZIP stays until Files confirms the save. The record
/// is what survives a launch, so the Save again and Delete choice
/// returns when Empo received no result, and a deferred import finds
/// its package again.
public struct PackageRecord: Codable, Equatable, Identifiable, Sendable {

    public static let fileName = "package.json"

    public var id: String
    public var kind: PackageKind
    public var fileName: String
    /// The game the package covers, or `nil` for a library package.
    public var gameName: String?
    public var createdAt: Date
    public var isSaved: Bool

    public init(
        id: String,
        kind: PackageKind,
        fileName: String,
        gameName: String? = nil,
        createdAt: Date,
        isSaved: Bool
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.gameName = gameName
        self.createdAt = createdAt
        self.isSaved = isSaved
    }

    public func directory(localRoot: URL) -> URL {
        BackupRootLayout(root: localRoot).package(id: id)
    }

    public func zipURL(localRoot: URL) -> URL {
        directory(localRoot: localRoot).appendingPathComponent(fileName)
    }

    public func save(in directory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Every package still in staging, newest first.
    public static func all(localRoot: URL) -> [PackageRecord] {
        let fm = FileManager.default
        let root = BackupRootLayout(root: localRoot).packages
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return
            names
            .compactMap { name -> PackageRecord? in
                let file = root.appendingPathComponent(name).appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(PackageRecord.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The package that still waits for a save, per 12.5.
    public static func waitingForASave(localRoot: URL) -> PackageRecord? {
        all(localRoot: localRoot).first { record in
            record.kind == .built
                && PackageSaveChoice.asks(
                    isComplete: FileManager.default.fileExists(
                        atPath: record.zipURL(localRoot: localRoot).path),
                    isSaved: record.isSaved)
        }
    }

    public func markSaved(localRoot: URL) {
        var copy = self
        copy.isSaved = true
        copy.save(in: directory(localRoot: localRoot))
        // Files owns the copy now, and Empo keeps no second one, per
        // 12.5.
        try? FileManager.default.removeItem(at: directory(localRoot: localRoot))
    }

    public func delete(localRoot: URL) {
        try? FileManager.default.removeItem(at: directory(localRoot: localRoot))
    }
}
