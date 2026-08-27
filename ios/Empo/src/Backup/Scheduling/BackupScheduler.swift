import Foundation
import GameProbe
import UIKit

/// What one backup pass does.
///
/// The scheduler owns when a pass runs. It owns nothing about what a
/// pass does, because that needs a provider and ticket 008 brings the
/// first one. Until a runner registers, every trigger does its gate
/// work and stops.
@MainActor
protocol BackupRunning: AnyObject {
    /// Runs one pass.
    ///
    /// `progress` belongs to a continued-processing task, which must
    /// report progress or the system expires it. The pass must check
    /// `Task.isCancelled` at every file boundary, per 7.6.
    func runBackup(
        scope: BackupScanScope, trigger: BackupTrigger, progress: Progress?
    ) async -> BackupPassResult
}

/// What a pass reports back to the scheduler.
struct BackupPassResult: Sendable {
    /// True when the pass did all the work it planned.
    var didFinish: Bool
    /// One row for each target the pass touched.
    var targets: [BackupPassTarget]

    init(didFinish: Bool = false, targets: [BackupPassTarget] = []) {
        self.didFinish = didFinish
        self.targets = targets
    }
}

/// One target as a pass left it. A target with no cause re-arms its
/// notifications, per 7.11, so a clean target still belongs here.
struct BackupPassTarget: Sendable {
    var id: String
    var label: String
    var causes: Set<BackupFailFastCause>

    init(id: String, label: String, causes: Set<BackupFailFastCause> = []) {
        self.id = id
        self.label = label
        self.causes = causes
    }
}

/// The one place that decides when a backup run starts, per SPEC 7.
///
/// The rules it applies are pure and live in GameProbe. This file
/// holds what only iOS answers: the app lifetime, the background
/// grant, the device conditions, and the two background tasks.
@MainActor
final class BackupScheduler {

    static let shared = BackupScheduler()

    private init() {}

    /// What one pass does. Ticket 008 set it to `BackupPass`.
    var runner: (any BackupRunning)?

    /// Why staging is not running, per 7.5 and 7.6, or `nil` while
    /// nothing holds it. The screens of section 13 read it.
    private(set) var pause: StagingPause?

    /// The network cause the stale line carries, per 7.4. It is
    /// `waitingForWiFi` while the switch is off and the device is on
    /// cellular.
    private(set) var networkCause: StaleCause?

    /// The written detail of a run the process did not survive.
    static let interruptedDetail = "the run stopped when Empo closed"

    private var didStart = false
    private var isRunning = false
    private var foregroundWait: Task<Void, Never>?
    private lazy var store: BackupStateStore? = try? BackupRoot.openStateStore()

    // MARK: - Launch

    /// Starts the schedule. The scene delegate calls this once.
    ///
    /// `BackupTaskScheduler.register()` is not here. iOS wants every
    /// launch handler in place before launch ends, so the app
    /// delegate calls it earlier.
    func start() {
        guard !didStart else { return }
        didStart = true

        BackupRoot.prepare()
        BackupNetwork.start()
        BackupTransferSession.shared.start()
        ICloudDriveGate.shared.start()
        runner = BackupPass.shared
        observeAppLifetime()
        BackupTaskScheduler.scheduleNightly()
        countTheRunsThatVanished()
        log("the schedule started")
        runTheDeviceCheck()
    }

    /// Runs the launch arguments a device check needs, in order.
    ///
    /// `-backupAddICloud YES`, `-backupAddDropbox YES`,
    /// `-backupAddGoogleDrive YES`, and `-backupAddS3 YES` add a
    /// target through the permission check of 8.7.
    /// `-backupPressNow YES` then presses "Back up now". An add
    /// finishes first, because a press that beat it would find no
    /// target and the pass would end at once.
    ///
    /// Tickets 016 and 017 bring the screens that carry all of them.
    /// Delete this when they land, with the two holds beside it.
    private func runTheDeviceCheck() {
        let addsICloud = UserDefaults.standard.bool(forKey: "backupAddICloud")
        let addsDropbox = UserDefaults.standard.bool(forKey: "backupAddDropbox")
        let addsGoogleDrive = UserDefaults.standard.bool(forKey: "backupAddGoogleDrive")
        let addsS3 = UserDefaults.standard.bool(forKey: "backupAddS3")
        let presses = UserDefaults.standard.bool(forKey: "backupPressNow")
        let uploadsBig = UserDefaults.standard.bool(forKey: "backupBigUpload")
        let rearms = UserDefaults.standard.bool(forKey: "backupRearmNotifications")
        guard
            addsICloud || addsDropbox || addsGoogleDrive || addsS3 || presses || uploadsBig
                || rearms
        else {
            return
        }

        // `-backupS3SmallParts YES` lowers the two upload numbers of
        // 9.4, so the big upload takes the multipart path with a file
        // a phone can write. A real 5 GiB file is not a device check.
        if UserDefaults.standard.bool(forKey: "backupS3SmallParts") {
            let sixteenMebibytes: Int64 = 16 * 1024 * 1024
            S3Gate.shared.useSmallParts(
                singleUploadLimit: sixteenMebibytes, partBase: sixteenMebibytes)
            log("S3 uploads in parts of 16 MiB for this check")
        }

        // A cause posts once, per 7.11, so a second device check on
        // the same cause stays silent. This re-arms the ledger the
        // way a rebuilt cache does.
        if rearms, let store = self.store {
            try? store.saveNotificationLedger(BackupNotificationLedger())
            log("the notification ledger is empty again")
        }

        Task {
            // Ticket 016 brings the add flow that asks. Until then a
            // device check has no other way to reach the permission,
            // and the notification of 7.11 cannot fire without it.
            await BackupNotifier.askForPermissionIfNeeded(
                configuredTargetCount: BackupTargets.load().count)
            if addsICloud { await self.addTheICloudTarget() }
            if addsDropbox { await self.addTheDropboxTarget() }
            if addsGoogleDrive { await self.addTheGoogleDriveTarget() }
            if addsS3 { await self.addTheS3Target() }
            if uploadsBig { await self.uploadOneBigFile() }
            if presses { self.pressBackUpNow(.library) }
        }
    }

    /// How large the file of the big-upload check is.
    ///
    /// Dropbox takes one `files/upload` up to 150 MiB. A larger file
    /// takes `upload_session/start`, an `append_v2` per chunk, and
    /// `finish`, so 200 MiB proves the second path. Google Drive
    /// takes a simple upload up to 5 MB, per 9.3, so the same file
    /// proves its resumable path too.
    private static let bigUploadBytes = 200 * 1024 * 1024

    /// Puts one large file, confirms it, and deletes it.
    ///
    /// A small library never reaches the limit, so a real game cannot
    /// prove the chunked upload. This writes the bytes instead.
    ///
    /// `-backupBigUploadProvider s3` names the target. It takes
    /// Dropbox by default, because ticket 009 wrote the check.
    private func uploadOneBigFile() async {
        let name = UserDefaults.standard.string(forKey: "backupBigUploadProvider")
        let kind = name.flatMap(BackupProviderKind.init(rawValue:)) ?? .dropbox
        guard let descriptor = BackupTargets.load().first(where: { $0.provider == kind }) else {
            log("the big upload found no \(kind.rawValue) target")
            return
        }
        guard let provider = await BackupTargets.provider(for: descriptor) else {
            log("the big upload could not open the target")
            return
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("big-upload-check.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        guard Self.writeZeroes(Self.bigUploadBytes, to: file) else {
            log("the big upload could not write its file")
            return
        }
        log("the big upload starts, \(Self.bigUploadBytes) bytes")

        let path = BackupNamespacePaths.join(
            BackupNamespacePaths.join(descriptor.root, BackupNamespacePaths.empoDirectoryName),
            "big-upload-check.bin")
        do {
            try await provider.put(localFile: file, path: path)
            let confirmation = try await provider.confirm(path: path)
            log("the big upload confirms \(confirmation)")
            let found = try await provider.list(prefix: path)
            log("the big upload lists \(found.count) object, \(found.first?.sizeBytes ?? -1) bytes")
            try await provider.delete(paths: [path])
            log("the big upload deleted its file")
        } catch {
            log("the big upload failed: \(error)")
        }
    }

    /// Writes a file of zeroes without holding it all in memory.
    private static func writeZeroes(_ bytes: Int, to file: URL) -> Bool {
        let chunk = Data(count: 4 * 1024 * 1024)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: file) else { return false }
        defer { try? handle.close() }
        var left = bytes
        while left > 0 {
            let size = min(left, chunk.count)
            guard (try? handle.write(contentsOf: chunk.prefix(size))) != nil else { return false }
            left -= size
        }
        return true
    }

    /// Signs in to Dropbox and adds the target, per 8.10 and 9.2.
    ///
    /// The sign-in needs a view controller to present its browser, so
    /// this waits for the scene to draw one.
    private func addTheDropboxTarget() async {
        guard DropboxSignIn.isConfigured else {
            log("this build carries no Dropbox app key")
            return
        }
        guard let presenter = await OAuthSignIn.screenForTheSheet() else {
            log("Dropbox found no screen to sign in from")
            return
        }

        let descriptor = TargetDescriptor(
            id: "dropbox",
            provider: .dropbox,
            label: "Dropbox",
            accountHint: "this account",
            root: Dropbox.root)
        do {
            let signedIn = try await DropboxGate.shared.signIn(
                targetId: descriptor.id, presenting: presenter)
            guard signedIn else {
                log("the user closed the Dropbox browser")
                return
            }
        } catch {
            log("the Dropbox sign-in failed: \(error.localizedDescription)")
            return
        }

        guard let provider = DropboxGate.shared.target(for: descriptor) else {
            log("Dropbox signed in and still cannot open")
            return
        }
        await reportThePermissionCheck(descriptor, provider: provider)
    }

    /// Runs the permission check of 8.7 and writes every step to the
    /// log a device check reads.
    private func reportThePermissionCheck(
        _ descriptor: TargetDescriptor, provider: some BackupProvider
    ) async {
        guard
            let result = try? await BackupTargets.addAfterPermissionCheck(
                descriptor, provider: provider)
        else {
            log("the permission check could not run")
            return
        }
        for step in result.steps {
            log("the permission check: \(step.label) \(step.outcome)")
        }
        if let quota = result.quota {
            log("the free space: \(quota.usedBytes) used of \(quota.limitBytes ?? -1)")
        }
        log("the target was added: \(result.allowsAdd)")
    }

    /// Signs in to Google Drive and adds the target, per 8.10 and 9.3.
    ///
    /// The sign-in needs a view controller to present its browser, so
    /// this waits for the scene to draw one.
    private func addTheGoogleDriveTarget() async {
        guard GoogleDriveSignIn.isConfigured else {
            log("this build carries no Google Drive client id")
            return
        }
        guard let presenter = await OAuthSignIn.screenForTheSheet() else {
            log("Google Drive found no screen to sign in from")
            return
        }

        let descriptor = TargetDescriptor(
            id: "google-drive",
            provider: .googleDrive,
            label: "Google Drive",
            accountHint: "this account",
            root: GoogleDrive.root)
        do {
            let signedIn = try await GoogleDriveGate.shared.signIn(
                targetId: descriptor.id, presenting: presenter)
            guard signedIn else {
                log("the user closed the Google Drive browser")
                return
            }
        } catch {
            log("the Google Drive sign-in failed: \(error.localizedDescription)")
            return
        }

        guard let provider = GoogleDriveGate.shared.target(for: descriptor) else {
            log("Google Drive signed in and still cannot open")
            return
        }
        await reportThePermissionCheck(descriptor, provider: provider)
    }

    /// Adds an S3-compatible target and writes each step of the
    /// permission check of 8.7 to the log, per 9.4.
    ///
    /// S3 has no browser step. The user types the bucket and the
    /// access key, so a device check types them as launch arguments
    /// until ticket 016 draws the form:
    /// `-backupS3Address https://s3.eu-west-1.amazonaws.com`,
    /// `-backupS3Bucket my-saves`, `-backupS3Region eu-west-1`,
    /// `-backupS3AccessKeyId ...`, `-backupS3SecretAccessKey ...`,
    /// and the optional `-backupS3Root empo` and
    /// `-backupS3PathStyle YES`.
    private func addTheS3Target() async {
        let defaults = UserDefaults.standard
        guard
            let address = defaults.string(forKey: "backupS3Address").flatMap(URL.init(string:)),
            let bucketName = defaults.string(forKey: "backupS3Bucket"),
            let keyId = defaults.string(forKey: "backupS3AccessKeyId"),
            let secret = defaults.string(forKey: "backupS3SecretAccessKey")
        else {
            log("the S3 check needs an address, a bucket, and an access key")
            return
        }

        let bucket = S3Bucket(
            address: address,
            region: defaults.string(forKey: "backupS3Region") ?? "auto",
            name: bucketName,
            usesPathStyle: defaults.object(forKey: "backupS3PathStyle") == nil
                ? S3Bucket.prefersPathStyle(address: address)
                : defaults.bool(forKey: "backupS3PathStyle"))
        let connection = S3Connection(
            bucket: bucket,
            credentials: S3SigV4.Credentials(accessKeyId: keyId, secretAccessKey: secret))

        if let refusal = bucket.refusal {
            log("the S3 check refuses this bucket: \(refusal)")
            return
        }

        let descriptor = TargetDescriptor(
            id: "s3",
            provider: .s3,
            label: bucketName,
            accountHint: connection.accountHint,
            root: defaults.string(forKey: "backupS3Root") ?? "")
        do {
            let provider = try S3Gate.shared.connect(connection, targetId: descriptor.id)
            await reportThePermissionCheck(descriptor, provider: provider)
        } catch {
            log("the S3 key could not go in the Keychain: \(error)")
        }
    }

    /// Adds the iCloud Drive target and writes each step of the
    /// permission check of 8.7 to the log.
    private func addTheICloudTarget() async {
        guard let provider = await ICloudDriveGate.shared.target() else {
            log("iCloud is not available on this device")
            return
        }
        let descriptor = TargetDescriptor(
            id: "icloud-drive",
            provider: .iCloudDrive,
            label: "iCloud Drive",
            accountHint: "this device",
            root: ICloudDrive.root)
        guard
            let result = try? await BackupTargets.addAfterPermissionCheck(
                descriptor, provider: provider)
        else {
            log("the permission check could not run")
            return
        }
        for step in result.steps {
            log("the permission check: \(step.label) \(step.outcome)")
        }
        log("the target was added: \(result.allowsAdd)")
    }

    private func observeAppLifetime() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackupScheduler.shared.appDidEnterBackground() }
        }
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { BackupScheduler.shared.appDidBecomeActive() }
        }
    }

    // MARK: - The backbone

    /// Runs the backbone pass as the app goes to the background.
    ///
    /// A live session stops it, per 7.6. A background pause keeps the
    /// player view mounted, so a paused session still counts as live
    /// and backgrounding during play is not session end.
    private func appDidEnterBackground() {
        foregroundWait?.cancel()
        foregroundWait = nil
        guard !BackupDeviceConditions.isSessionLive else { return }
        Task { await runUnderTheGrant(.sessionEndOrBackground) }
    }

    /// The other half of the backbone. `AppState` calls it once the
    /// engine terminates and the session is over.
    func playSessionDidEnd(game: GameEntry?) {
        if let container = game?.container {
            markDirty(container: container, reason: "play session")
        }
        Task { await runUnderTheGrant(.sessionEndOrBackground) }
    }

    /// Marks a game for the next backbone pass, which scans dirty
    /// games alone.
    func markDirty(container: GameContainer, reason: String) {
        let gameKey = BackupKeys.gameKey(containerFolderName: container.folderName)
        try? store?.markDirty(gameKey: gameKey, reason: reason, at: Date())
    }

    private func runUnderTheGrant(_ trigger: BackupTrigger) async {
        await BackupBackgroundTask.run(named: "backup.\(trigger.rawValue)") {
            await BackupScheduler.shared.run(trigger: trigger)
            await BackupBackgroundTask.holdForADeviceCheck()
        }
    }

    // MARK: - The catch-up pass

    /// Starts the 30-second wait of 7.3. Launching Empo and tapping
    /// into a game scans nothing, because the wait never ends.
    private func appDidBecomeActive() {
        guard foregroundWait == nil, !BackupDeviceConditions.isSessionLive else { return }
        foregroundWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BackupTriggerPlan.foregroundDelay))
            guard !Task.isCancelled else { return }
            self?.foregroundWait = nil
            await self?.run(trigger: .foreground)
        }
    }

    // MARK: - The manual button

    /// "Back up now", from the Backup sheet of one game or from the
    /// Backups screen. There is no third entry point, per 13.11.
    func pressBackUpNow(_ press: ManualBackupPress) {
        guard !BackupTaskScheduler.submitManual(press) else { return }
        // The system refused the task, so the pass runs in the
        // foreground and hands its uploads to the background session.
        Task { await run(trigger: .manual, press: press) }
    }

    // MARK: - One pass

    /// Applies the gates of 7.4, 7.5, and 7.6, then hands the pass to
    /// the runner.
    @discardableResult
    func run(
        trigger: BackupTrigger,
        press: ManualBackupPress? = nil,
        progress: Progress? = nil
    ) async -> Bool {
        guard !isRunning else { return false }

        let conditions = BackupDeviceConditions.now(isManual: trigger == .manual)
        switch ResourcePolicy.stagingGate(conditions) {
        case .pause(let reason):
            pause = reason
            log("%@ paused: %@", trigger.rawValue, reason.line)
            close(progress)
            return false
        case .run:
            pause = nil
        }

        // The uploads wait inside the transfer daemon, and the stale
        // line says what they wait for. Staging still runs, because
        // the clock of 7.1 runs while Empo's own policy blocks the
        // run.
        networkCause = ResourcePolicy.blockedCause(
            policy: BackupNetwork.policy, isOnCellular: BackupNetwork.isOnCellular)

        log(
            "%@ runs, network %@",
            trigger.rawValue, networkCause == nil ? "clear" : BackupNetwork.waitingLine)

        guard let runner else {
            // Ticket 008 brings the first provider. Until then the
            // gates run and the pass stops here.
            log("%@ has no runner yet", trigger.rawValue)
            await holdTheLiveActivityForADeviceCheck(progress)
            close(progress)
            return false
        }

        isRunning = true
        defer { isRunning = false }
        progress?.totalUnitCount = 1

        let result = await runner.runBackup(
            scope: BackupTriggerPlan.scope(of: trigger, press: press),
            trigger: trigger,
            progress: progress)

        close(progress)
        record(result.didFinish ? .succeeded : .otherFailure)
        report(result.targets)
        return result.didFinish
    }

    /// Walks the progress of a continued-processing task for a
    /// minute, when the process starts with `-backupHoldManual YES`.
    ///
    /// The device check of ticket 007 has to see the Live Activity
    /// the system draws for the task. A pass with no runner ends in
    /// milliseconds, which is too fast to see. Delete this when
    /// ticket 016 lands.
    private func holdTheLiveActivityForADeviceCheck(_ progress: Progress?) async {
        guard let progress else { return }
        guard UserDefaults.standard.bool(forKey: "backupHoldManual") else { return }
        let steps: Int64 = 60
        progress.totalUnitCount = steps
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            progress.completedUnitCount = step
            log("the Live Activity shows %ld of %ld", step, steps)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The one line a device check reads. The Backups screen of
    /// ticket 016 shows the same state on screen.
    private func log(_ format: String, _ arguments: CVarArg...) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("BackupScheduler", String(format: format, arguments: arguments))
    }

    /// A continued-processing task that stops reporting progress is
    /// expired by the system, so every exit closes it.
    private func close(_ progress: Progress?) {
        guard let progress else { return }
        progress.totalUnitCount = max(progress.totalUnitCount, 1)
        progress.completedUnitCount = progress.totalUnitCount
    }

    // MARK: - Force quit

    /// Counts the runs that vanished with the process, per 7.10.
    ///
    /// Empo cannot see a force quit. What it sees at launch is a run
    /// row that never finished while the background session carries
    /// no task for it. The foreground pass then restarts the work.
    private func countTheRunsThatVanished() {
        Task { [weak self] in
            let live = await BackupTransferSession.shared.liveTaskPaths()
            // The daemon still carries the run, so the process death
            // cost nothing.
            guard live.isEmpty else { return }
            self?.closeTheRunsThatVanished()
        }
    }

    private func closeTheRunsThatVanished() {
        guard let store else { return }
        let open = ((try? store.runHistory()) ?? []).filter { $0.finishedAt == nil }
        guard !open.isEmpty else { return }

        // One launch counts one interrupted run, however many targets
        // the run covered.
        record(.interrupted)

        let now = Date()
        for var row in open {
            row.finishedAt = now
            row.detail = Self.interruptedDetail
            try? store.recordRun(row)
        }
    }

    private func record(_ ending: InterruptedRunEnding) {
        guard let store, let tally = try? store.interruptedRunTally() else { return }
        try? store.saveInterruptedRunTally(tally.recording(ending))
    }

    // MARK: - The three notifications

    /// Reports every target the pass touched, per 7.11. A target with
    /// no cause re-arms, so a clean target must come through here.
    private func report(_ targets: [BackupPassTarget]) {
        guard let store else { return }
        for target in targets {
            BackupNotifier.report(
                causes: target.causes,
                targetId: target.id,
                targetLabel: target.label,
                store: store)
        }
    }
}
