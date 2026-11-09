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
}

/// The signed-in account of an OAuth service.
public struct BackupAccount: Equatable, Sendable {
    public var name: String?
    public var email: String?
    public var photo: URL?

    public init(name: String?, email: String?, photo: URL?) {
        self.name = name
        self.email = email
        self.photo = photo
    }

    init?(jsonName name: Any?, email: Any?, photo: Any?) {
        let name = (name as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (email as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard name != nil || email != nil else { return nil }
        self.init(name: name, email: email, photo: (photo as? String).flatMap(URL.init(string:)))
    }
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
    /// The account owner's name and photo, as the service reports
    /// them. They stay on this device, like the account hint.
    public var accountName: String?
    public var accountPhoto: URL?
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
        accountName: String? = nil,
        accountPhoto: URL? = nil,
        root: String,
        sizeThresholdBytes: Int64? = nil,
        capBytes: Int64? = nil,
        isPaused: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.accountHint = accountHint
        self.accountName = accountName
        self.accountPhoto = accountPhoto
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
        copy.accountName = nil
        copy.accountPhoto = nil
        return copy
    }

    /// This device's copy after a document of 10.8 arrives: every
    /// field the document carries, and this device's own account
    /// hint. It is the other half of `forSyncDocument()`.
    public func withSyncedFields(from incoming: TargetDescriptor) -> TargetDescriptor {
        var copy = incoming
        copy.accountHint = accountHint
        copy.accountName = accountName
        copy.accountPhoto = accountPhoto
        return copy
    }

    public mutating func take(_ account: BackupAccount) {
        accountHint = account.email ?? account.name ?? accountHint
        accountName = account.name
        accountPhoto = account.photo
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        targets = try container.decode([StoredTarget].self, forKey: .targets).compactMap(\.target)
    }

    /// A target whose service this build does not know is skipped, so
    /// the rest still read.
    private struct StoredTarget: Decodable {
        let target: TargetDescriptor?

        init(from decoder: Decoder) throws {
            let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .provider)
            target = BackupProviderKind(rawValue: kind) == nil ? nil : try TargetDescriptor(from: decoder)
        }

        private enum Key: String, CodingKey { case provider }
    }

    public static func decode(json data: Data) throws -> TargetDescriptorFile {
        try JSONDecoder().decode(TargetDescriptorFile.self, from: data)
    }

    public static func read(applicationSupport: URL) throws -> TargetDescriptorFile {
        let url = BackupRootLayout(applicationSupport: applicationSupport).targetsFile
        return try SettingsFile.value(
            at: url, empty: { TargetDescriptorFile() }, decode: decode(json:))
    }

    public func write(applicationSupport: URL) throws {
        let url = BackupRootLayout(applicationSupport: applicationSupport).targetsFile
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }
}
