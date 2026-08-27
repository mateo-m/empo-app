import Foundation

/// Whether this device can open the iCloud Drive container, per
/// SPEC 9.1.
///
/// The gate is two reads and never a build flag: the identity token
/// on the main thread, then the container URL off it, because that
/// call blocks. Both must answer.
public enum ICloudAvailability: Equatable, Sendable {

    /// Both reads answered, so the target opens.
    case ready
    /// No Apple ID is signed in on this device.
    case notSignedIn
    /// The build holds no entitlement for the container, so the
    /// container URL came back nil. A sideloaded Empo is always
    /// here, per 9.1.
    case noContainer

    public var isReady: Bool { self == .ready }
}

/// The one state a target row shows, per SPEC 13.5. "Cannot open in
/// this build" outranks every other state on that list.
public enum ICloudRowState: Equatable, Sendable {

    case usable
    /// The row keeps its place and the target is not deleted, per
    /// 9.1. Only the entry in the add flow's service list hides.
    case cannotOpen(line: String)
}

/// The iCloud Drive profile of SPEC 9.1.
///
/// The provider itself needs a real ubiquity container, so it lives
/// in the app target. Everything a test can reach is here: the
/// runtime gate, the row state, the five capability flags, and the
/// map from a Cocoa error onto the seven kinds of 8.4.
public enum ICloudDrive {

    /// The exact container string, with no team id in front of it,
    /// per 9.1.
    public static let containerIdentifier = "iCloud.sh.mateo.empo"

    /// The fixed root of 8.7, inside the container. The
    /// `NSUbiquitousContainers` entry in `Info.plist` makes it
    /// visible in the Files app.
    public static let root = "Documents/Empo Backups"

    /// What the row reads while the probe answers nil, per 9.1 and
    /// 13.5.
    public static let disabledLine = "iCloud is off or not signed in on this device"

    /// The five flags of 8.3, as the table of section 9 states them.
    ///
    /// There is no space query, per 9.7, so a full account shows up
    /// as an upload error and 5.14 runs its ladder from it. The
    /// transfer rides the system daemon, outside the app's lifetime,
    /// so no background URLSession is involved. The account quota
    /// bounds the file size and 9.1 states no number.
    public static let capabilities = TargetCapabilities(
        canQueryQuota: false,
        reportsObjectAge: true,
        supportsBackgroundTransfer: true,
        maxFileSize: nil,
        foldsCase: false)

    // MARK: - The runtime gate

    /// The gate of 9.1, from the two reads the app makes.
    ///
    /// It answers `ready` only when both are non-nil. The check is at
    /// runtime, every launch, and never on a build flag.
    public static func availability(
        hasIdentityToken: Bool, containerURL: URL?
    ) -> ICloudAvailability {
        guard hasIdentityToken else { return .notSignedIn }
        guard containerURL != nil else { return .noContainer }
        return .ready
    }

    /// Whether the add flow lists iCloud Drive, per 9.1 and 13.7.
    /// This is the one entry that hides.
    public static func showsInAddFlow(_ availability: ICloudAvailability) -> Bool {
        availability.isReady
    }

    /// The row state of one configured target, or `nil` for a target
    /// on another service, which 9.1 says nothing about.
    ///
    /// A configured iCloud target whose probe turns nil is disabled,
    /// not deleted.
    public static func rowState(
        of target: TargetDescriptor, availability: ICloudAvailability
    ) -> ICloudRowState? {
        guard target.provider == .iCloudDrive else { return nil }
        return availability.isReady ? .usable : .cannotOpen(line: disabledLine)
    }

    // MARK: - The error map

    /// The Cocoa codes iCloud Drive reports. The name beside each
    /// number is Apple's own.
    public enum CocoaCode {
        /// `NSFileNoSuchFileError`
        public static let noSuchFile = 4
        /// `NSFileReadNoPermissionError`
        public static let readNoPermission = 257
        /// `NSFileReadNoSuchFileError`
        public static let readNoSuchFile = 260
        /// `NSFileWriteNoPermissionError`
        public static let writeNoPermission = 513
        /// `NSFileWriteOutOfSpaceError`
        public static let writeOutOfSpace = 640
        /// `NSUbiquitousFileUnavailableError`
        public static let ubiquitousFileUnavailable = 4353
        /// `NSUbiquitousFileNotUploadedDueToQuotaError`
        public static let notUploadedDueToQuota = 4354
        /// `NSUbiquitousFileUbiquityServerNotAvailable`
        public static let serverNotAvailable = 4355
    }

    /// One iCloud failure as one of the seven kinds of 8.4.
    ///
    /// `confirm` reads `NSMetadataUbiquitousItemUploadingErrorKey`
    /// and maps it here. A full account arrives as the quota code,
    /// and it is the only way a full account shows up on iCloud,
    /// because 9.7 gives this target no space query.
    ///
    /// A code with no rule becomes `rejected`, which carries the
    /// system's own sentence to the user word for word, per 8.4.
    public static func error(
        domain: String, code: Int, description: String
    ) -> BackupProviderError {
        switch domain {
        case NSCocoaErrorDomain:
            switch code {
            case CocoaCode.writeOutOfSpace, CocoaCode.notUploadedDueToQuota:
                return .outOfSpace
            case CocoaCode.serverNotAvailable:
                return .offline
            case CocoaCode.readNoPermission, CocoaCode.writeNoPermission:
                return .permissionDenied
            case CocoaCode.noSuchFile, CocoaCode.readNoSuchFile,
                CocoaCode.ubiquitousFileUnavailable:
                return .notFound
            default:
                return .rejected(message: description)
            }
        case NSURLErrorDomain:
            // The device has no route to iCloud. The next pass tries
            // again and nothing reaches the user, per 8.4.
            return .offline
        default:
            return .rejected(message: description)
        }
    }
}

/// The launch-long cache of the gate, per SPEC 9.1.
///
/// Empo probes once per launch and probes again when
/// `NSUbiquityIdentityDidChange` arrives. Between those two moments
/// every reader gets the same answer, so a list and a row cannot
/// disagree inside one pass.
public struct ICloudProbeCache: Equatable, Sendable {

    private var cached: ICloudAvailability?

    /// How many probes the cache took. The reprobe of 9.1 raises it.
    public private(set) var probeCount = 0

    public init() {}

    /// The cached answer, or `nil` when the next read must probe.
    public var value: ICloudAvailability? { cached }

    /// Keeps what a probe found for the rest of the launch.
    public mutating func record(_ availability: ICloudAvailability) {
        cached = availability
        probeCount += 1
    }

    /// `NSUbiquityIdentityDidChange` arrived, so the next read
    /// probes again. It drops the answer and never a target.
    public mutating func identityDidChange() {
        cached = nil
    }
}
