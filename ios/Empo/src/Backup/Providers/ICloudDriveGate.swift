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

    private init() {}

    /// What the last probe found, or `nil` before the first one.
    var lastAnswer: ICloudAvailability? { cache.value }

    /// Starts the reprobe of 9.1 and takes the first reading. The
    /// scheduler calls this once.
    func start() {
        observeIdentityChanges()
        Task { await probeAndLog() }
    }

    /// The gate's answer, from the cache or from a fresh probe.
    func availability() async -> ICloudAvailability {
        if let cached = cache.value { return cached }

        // Read 1, on the main thread. This actor is the main actor.
        let hasIdentityToken = FileManager.default.ubiquityIdentityToken != nil
        // Read 2, off the main thread, because it blocks.
        let containerURL = await Task.detached {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudDrive.containerIdentifier)
        }.value

        let answer = ICloudDrive.availability(
            hasIdentityToken: hasIdentityToken, containerURL: containerURL)
        cache.record(answer)
        self.containerURL = containerURL
        return answer
    }

    /// The target, or `nil` where the gate is closed.
    ///
    /// The add flow of 13.7 hides the iCloud entry on `nil`, and a
    /// configured target keeps its row and reads the line of 9.1.
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
        cache.identityDidChange()
        containerURL = nil
        watch = nil
        Task { await probeAndLog() }
    }

    private func probeAndLog() async {
        let answer = await availability()
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("ICloudDriveGate", "the probe answers \(answer)")
    }
}
