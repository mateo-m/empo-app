import CloudKit
import Foundation
import GameProbe

/// The one runtime gate in the design, per SPEC 9.1.
///
/// iCloud Drive is the only provider that can be absent from a
/// running build. The gate is two reads and never a build flag:
///
/// 1. `ubiquityIdentityToken` on the main thread.
/// 2. `url(forUbiquityContainerIdentifier:)` off the main thread,
///    because that call blocks.
///
/// It answers once per launch and answers again when
/// `NSUbiquityIdentityDidChange` arrives. A configured target whose
/// probe turns nil is disabled and never deleted.
///
/// The rule lives in `ICloudDrive`, inside GameProbe. This file makes
/// the two reads.
@MainActor
final class ICloudDriveGate {

    static let shared = ICloudDriveGate()

    private var cache = ICloudProbeCache()
    /// What the last probe read, or `nil` while the gate is closed.
    private var containerURL: URL?
    private var watch: ICloudUploadWatch?
    private var didObserve = false
    private var identityChanges = 0

    private init() {}

    /// Starts the reprobe of 9.1 and takes the first reading. The
    /// scheduler calls this once.
    func start() {
        observeIdentityChanges()
        Task { await probeAndLog() }
    }

    /// The gate's answer, from the cache or from a fresh probe.
    func availability() async -> ICloudAvailability {
        if let cached = cache.value { return cached }
        let identityChangesBefore = identityChanges

        // Read 1, on the main thread. This actor is the main actor.
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        // Read 2, off the main thread, because it blocks.
        let containerURL = await Task.detached {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudDrive.containerIdentifier)
        }.value

        let answer = ICloudDrive.availability(
            hasIdentityToken: hasIdentityToken, containerURL: containerURL,
            hasAppleAccount: hasIdentityToken ? nil : await Self.hasAppleAccount())
        // The reads above are of the account from before the change.
        guard identityChanges == identityChangesBefore else { return await availability() }
        cache.record(answer)
        self.containerURL = containerURL
        return answer
    }

    /// CloudKit stops the app with a trap, which nothing can catch,
    /// when the signature has no CloudKit entitlement. Tools that
    /// re-sign a sideloaded build remove it.
    private static func hasAppleAccount() async -> Bool? {
        guard SignedEntitlements.allowCloudKit(in: ICloudDrive.containerIdentifier) else {
            return nil
        }
        // A CloudKit error says nothing about the account. Keep the
        // iCloud Drive line, which the app showed before this check.
        let container = CKContainer(identifier: ICloudDrive.containerIdentifier)
        guard let status = try? await container.accountStatus() else { return true }
        return status != .noAccount
    }

    /// The target, or `nil` where the gate is closed.
    func target() async -> ICloudDriveTarget? {
        guard await availability().isReady, let containerURL else { return nil }
        let watch = watch ?? ICloudUploadWatch()
        self.watch = watch
        watch.start()
        return ICloudDriveTarget(containerURL: containerURL, watch: watch)
    }

    /// The row state of one configured target, per 9.1 and 13.5.
    func rowState(of target: TargetDescriptor) async -> ICloudRowState? {
        ICloudDrive.rowState(of: target, availability: await availability())
    }

    // MARK: - The reprobe

    private func observeIdentityChanges() {
        guard !didObserve else { return }
        didObserve = true
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSUbiquityIdentityDidChange,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ICloudDriveGate.shared.identityDidChange() }
        }
    }

    /// The user signed in or out of iCloud. The next read probes
    /// again, and the target stays.
    private func identityDidChange() {
        identityChanges += 1
        cache.identityDidChange()
        containerURL = nil
        watch?.stop()
        watch = nil
        Task { await probeAndLog() }
    }

    private func probeAndLog() async {
        let answer = await availability()
        BackupLog.debug("ICloudDriveGate", "the probe answers \(answer)")
    }
}
