import Foundation

/// One stream inside a package: one game, or the stream that belongs
/// to no game, per SPEC 5.3.
public struct PackageStream: Codable, Equatable, Sendable {

    /// The stream key of 5.3. `BackupStream(key:)` reads it back.
    public var key: String
    /// The name the restore picker shows. The preferences stream
    /// carries none.
    public var gameName: String?
    /// The snapshot, in the data model of 5.5.
    public var manifest: SnapshotManifest

    public init(key: String, gameName: String? = nil, manifest: SnapshotManifest) {
        self.key = key
        self.gameName = gameName
        self.manifest = manifest
    }
}

/// `manifest.json`, per SPEC 12.3.
///
/// It uses the data model of the snapshot manifest of 5.5, so an
/// import reads a package the way a restore reads a target. The
/// physical layout differs on purpose: a package stores the files at
/// their own paths, with no hashed blob tree and no deduplication.
/// That cost is what makes it readable without Empo.
///
/// The package version is its own integer, per 15.5. It is not
/// `formatVersion`, which each inner manifest still carries.
public struct PackageManifest: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public var packageVersion: Int
    public var exportedAt: Date
    /// The device that wrote the package, per 12.3. The restore
    /// picker shows it where a target restore shows a namespace.
    public var sourceDevice: String
    public var streams: [PackageStream]

    public init(
        packageVersion: Int = PackageManifest.currentVersion,
        exportedAt: Date,
        sourceDevice: String,
        streams: [PackageStream] = []
    ) {
        self.packageVersion = packageVersion
        self.exportedAt = exportedAt
        self.sourceDevice = sourceDevice
        self.streams = streams
    }

    /// Every entry with the stream it belongs to and the path it
    /// takes in the ZIP.
    public var files: [PackageFile] {
        streams.flatMap { stream in
            stream.manifest.entries.compactMap { entry in
                guard let path = PackageLayout.zipPath(of: entry, in: stream.manifest) else {
                    return nil
                }
                return PackageFile(streamKey: stream.key, zipPath: path, entry: entry)
            }
        }
    }

    public func stream(_ key: String) -> PackageStream? {
        streams.first { $0.key == key }
    }

    // MARK: - The JSON codec

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> PackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PackageManifest.self, from: data)
    }
}

/// One file of a package: which stream it belongs to, where it sits
/// in the ZIP, and what the manifest says about it.
public struct PackageFile: Equatable, Sendable {
    public var streamKey: String
    public var zipPath: String
    public var entry: SnapshotManifest.Entry
}
