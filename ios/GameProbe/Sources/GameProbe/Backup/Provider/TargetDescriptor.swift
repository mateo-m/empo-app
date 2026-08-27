import Foundation

/// The six services of SPEC section 9.
///
/// A provider is the service. A backup target is one configured use
/// of it, per section 8 and the glossary in `CONTEXT.md`.
public enum BackupProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case iCloudDrive = "icloud-drive"
    case dropbox = "dropbox"
    case googleDrive = "google-drive"
    case s3 = "s3"
    case webdav = "webdav"
    case sftp = "sftp"
}

/// The non-secret description of one backup target, per SPEC 8.8.
///
/// No token, key, or password may ever enter this type. Secrets live
/// in the Keychain, per 6.7, and a secret never enters a backup set,
/// a snapshot, or a backup package.
///
/// The descriptor also rides the sync document of section 10, which
/// is what lets a fresh install name a target it cannot open yet.
/// `forSyncDocument()` drops the account hint, because the hint
/// holds the user's account address or their host name and 5.7
/// states that the remote can read everything Empo writes.
public struct TargetDescriptor: Codable, Equatable, Sendable, Identifiable {

    public var id: String
    public var provider: BackupProviderKind
    /// The name the user typed for this target.
    public var label: String
    /// The account or the host this target opens. It stays on this
    /// device and never rides the sync document.
    public var accountHint: String?
    /// The fixed root of 8.7. The user never chooses a folder, and
    /// section 9 states the root per provider.
    public var root: String
    /// The per-target override of the size threshold of 3.5, or
    /// `nil` to follow the app-wide setting.
    public var sizeThresholdBytes: Int64?
    /// The optional cap on this target's total, per 5.14. `nil` is
    /// the default, meaning no cap.
    public var capBytes: Int64?
    public var isPaused: Bool

    public init(
        id: String,
        provider: BackupProviderKind,
        label: String,
        accountHint: String? = nil,
        root: String,
        sizeThresholdBytes: Int64? = nil,
        capBytes: Int64? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.accountHint = accountHint
        self.root = root
        self.sizeThresholdBytes = sizeThresholdBytes
        self.capBytes = capBytes
        self.isPaused = isPaused
    }

    /// The copy that rides the sync document of section 10, without
    /// the account hint.
    public func forSyncDocument() -> TargetDescriptor {
        var copy = self
        copy.accountHint = nil
        return copy
    }

    /// Whether this descriptor arrived without its account hint,
    /// which is what a target placeholder looks like on a device
    /// that has not signed in yet, per 8.8.
    public var isPlaceholder: Bool {
        accountHint == nil
    }
}

/// `targets.json` under Application Support, per SPEC 8.8 and 6.1.
public struct TargetDescriptorFile: Codable, Equatable, Sendable {

    /// The version this build writes.
    public static let currentVersion = 1

    public var version: Int
    public var targets: [TargetDescriptor]

    public init(
        version: Int = TargetDescriptorFile.currentVersion,
        targets: [TargetDescriptor] = []
    ) {
        self.version = version
        self.targets = targets
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(json data: Data) throws -> TargetDescriptorFile {
        try JSONDecoder().decode(TargetDescriptorFile.self, from: data)
    }

    /// Reads `targets.json`, or returns an empty file where none is
    /// there yet.
    public static func read(applicationSupport: URL) throws -> TargetDescriptorFile {
        let url = BackupRootLayout.targetsFile(applicationSupport: applicationSupport)
        guard let data = try? Data(contentsOf: url) else { return TargetDescriptorFile() }
        return try decode(json: data)
    }

    public func write(applicationSupport: URL) throws {
        let url = BackupRootLayout.targetsFile(applicationSupport: applicationSupport)
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }
}
