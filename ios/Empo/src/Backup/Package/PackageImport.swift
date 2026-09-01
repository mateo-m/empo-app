import Foundation
import GameProbe

/// The import of SPEC 12.6.
///
/// The picked file moves into the staging area first, so the restore
/// reads a file that no other app changes while it runs. The package
/// is a temporary restore source: it never becomes a device
/// namespace, it never offers adopt, and it never joins the
/// namespace list.
@MainActor
enum PackageImport {

    /// Moves the picked ZIP into staging and records it, per 12.6.
    static func stage(
        picked: URL, localRoot: URL = BackupRoot.url, at date: Date = Date()
    ) throws -> PackageRecord {
        let record = PackageRecord(
            id: UUID().uuidString,
            kind: .imported,
            fileName: picked.lastPathComponent,
            createdAt: date,
            isSaved: false)
        let directory = record.directory(localRoot: localRoot)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // A file the picker copied is ours to move. A file Files
        // opened in place is not, so that one gets copied under its
        // security scope.
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let destination = record.zipURL(localRoot: localRoot)
        do {
            try fm.moveItem(at: picked, to: destination)
        } catch {
            try fm.copyItem(at: picked, to: destination)
        }
        record.save(in: directory)
        return record
    }

    /// Opens a staged package. It throws a `PackageRejection` where
    /// the package fails a check of 12.6.
    static func open(
        _ record: PackageRecord, localRoot: URL = BackupRoot.url
    ) throws -> PackageSource {
        try PackageSource(zip: record.zipURL(localRoot: localRoot), packageId: record.id)
    }

    /// One row per included stream, with this device's version
    /// marker where it holds the game, per 12.6 and 11.10.
    static func rows(of source: PackageSource) -> [SnapshotRow] {
        var markers: [String: SnapshotManifest.VersionMarker] = [:]
        for stream in source.manifest.streams {
            guard let container = GameIdentities.match(SnapshotIdentity(manifest: stream.manifest))
            else { continue }
            markers[stream.key] = GameIdentities.versionMarker(for: container)
        }
        return PackageSource.rows(
            of: source.manifest, packageId: source.packageId, localVersionMarkers: markers)
    }

    /// A finished import deletes the staged package. The original in
    /// Files stays untouched, per 12.6.
    static func finish(_ record: PackageRecord, localRoot: URL = BackupRoot.url) {
        record.delete(localRoot: localRoot)
    }
}
