import Foundation
import GameProbe
import UIKit

/// The launch arguments a backup device check uses.
///
/// `-backupAddICloud YES`, `-backupAddDropbox YES`,
/// `-backupAddGoogleDrive YES`, `-backupAddS3 YES`, and
/// `-backupAddWebDAV YES` add a target through the permission check
/// of 8.7. `-backupPressNow YES` then presses "Back up now". An add
/// finishes first, because a press that beat it would find no target
/// and the pass would end at once.
///
/// Tickets 016 and 017 bring the screens that carry all of this.
/// Delete this file when they land.
@MainActor
enum BackupDeviceCheck {

    /// Runs what the launch arguments ask for, in order.
    static func run() {
        let defaults = UserDefaults.standard
        let addsICloud = defaults.bool(forKey: "backupAddICloud")
        let addsDropbox = defaults.bool(forKey: "backupAddDropbox")
        let addsGoogleDrive = defaults.bool(forKey: "backupAddGoogleDrive")
        let addsS3 = defaults.bool(forKey: "backupAddS3")
        let addsWebDAV = defaults.bool(forKey: "backupAddWebDAV")
        let presses = defaults.bool(forKey: "backupPressNow")
        let uploadsBig = defaults.bool(forKey: "backupBigUpload")
        let rearms = defaults.bool(forKey: "backupRearmNotifications")
        guard
            addsICloud || addsDropbox || addsGoogleDrive || addsS3 || addsWebDAV || presses
                || uploadsBig || rearms
        else {
            return
        }

        // `-backupS3SmallParts YES` lowers the two upload numbers of
        // 9.4, so the big upload takes the multipart path with a file
        // a phone can write. A real 5 GiB file is not a device check.
        if defaults.bool(forKey: "backupS3SmallParts") {
            let sixteenMebibytes: Int64 = 16 * 1024 * 1024
            S3Gate.shared.useSmallParts(
                singleUploadLimit: sixteenMebibytes, partBase: sixteenMebibytes)
            log("S3 uploads in parts of 16 MiB for this check")
        }

        // A cause posts once, per 7.11, so a second device check on
        // the same cause stays silent. This re-arms the ledger the
        // way a rebuilt cache does.
        if rearms, let store = try? BackupRoot.openStateStore() {
            try? store.saveNotificationLedger(BackupNotificationLedger())
            store.close()
            log("the notification ledger is empty again")
        }

        Task {
            // Ticket 016 brings the add flow that asks. Until then a
            // device check has no other way to reach the permission,
            // and the notification of 7.11 cannot fire without it.
            await BackupNotifier.askForPermissionIfNeeded(
                configuredTargetCount: BackupTargets.load().count)
            if addsICloud { await addTheICloudTarget() }
            if addsDropbox {
                await addTheOAuthTarget(
                    DropboxGate.shared,
                    descriptor: TargetDescriptor(
                        id: "dropbox", provider: .dropbox, label: "Dropbox",
                        accountHint: "this account", root: Dropbox.root))
            }
            if addsGoogleDrive {
                await addTheOAuthTarget(
                    GoogleDriveGate.shared,
                    descriptor: TargetDescriptor(
                        id: "google-drive", provider: .googleDrive, label: "Google Drive",
                        accountHint: "this account", root: GoogleDrive.root))
            }
            if addsS3 { await addTheS3Target() }
            if addsWebDAV { await addTheWebDAVTargets() }
            if uploadsBig { await uploadOneBigFile() }
            if presses { BackupScheduler.shared.pressBackUpNow(.library) }
        }
    }

    // MARK: - The big upload

    /// How large the file of the big-upload check is.
    ///
    /// Dropbox takes one `files/upload` up to 150 MiB. A larger file
    /// takes `upload_session/start`, an `append_v2` per chunk, and
    /// `finish`, so 200 MiB proves the second path. Google Drive
    /// takes a simple upload up to 5 MB, per 9.3, so the same file
    /// proves its resumable path too.
    private static let bigUploadBytes = 200 * 1024 * 1024

    /// The size the check writes. `-backupBigUploadMebibytes 1000`
    /// raises it, so a transfer runs long enough for the app to die
    /// in the middle of it, per step 3 of the S3 device check.
    private static var bigUploadSize: Int {
        let asked = UserDefaults.standard.integer(forKey: "backupBigUploadMebibytes")
        return asked > 0 ? asked * 1024 * 1024 : bigUploadBytes
    }

    /// Puts one large file, confirms it, and deletes it.
    ///
    /// A small library never reaches the limit, so a real game cannot
    /// prove the chunked upload. This writes the bytes instead.
    ///
    /// `-backupBigUploadProvider s3` names the target. It takes
    /// Dropbox by default, because ticket 009 wrote the check.
    private static func uploadOneBigFile() async {
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
        let bytes = bigUploadSize
        guard writeZeroes(bytes, to: file) else {
            log("the big upload could not write its file")
            return
        }
        log("the big upload starts, \(bytes) bytes")

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

    // MARK: - The adds

    /// Signs in to Dropbox or Google Drive and adds the target, per
    /// 8.10, 9.2, and 9.3.
    ///
    /// The sign-in needs a view controller to present its browser, so
    /// this waits for the scene to draw one.
    private static func addTheOAuthTarget<Gate: OAuthProviderGate>(
        _ gate: Gate, descriptor: TargetDescriptor
    ) async {
        let label = descriptor.label
        guard gate.showsInAddFlow else {
            log("this build carries no \(label) client id")
            return
        }
        guard let presenter = await OAuthSignIn.screenForTheSheet() else {
            log("\(label) found no screen to sign in from")
            return
        }
        do {
            let signedIn = try await gate.signIn(
                targetId: descriptor.id, presenting: presenter)
            guard signedIn else {
                log("the user closed the \(label) browser")
                return
            }
        } catch {
            log("the \(label) sign-in failed: \(error.localizedDescription)")
            return
        }
        guard let provider = gate.target(for: descriptor) else {
            log("\(label) signed in and still cannot open")
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
    private static func addTheS3Target() async {
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

    /// Adds one WebDAV target per address and writes each step of the
    /// permission check of 8.7 to the log, per 9.5.
    ///
    /// The device check of ticket 012 wants two servers at once: one
    /// that answers RFC 4331 and one that does not. So the address
    /// argument takes a list, and each address makes a target of its
    /// own.
    ///
    /// WebDAV has no browser step. The user types the address and the
    /// password, so a device check types them as launch arguments
    /// until ticket 016 draws the form:
    /// `-backupWebDAVAddresses "https://a/dav https://b/dav"`,
    /// `-backupWebDAVUser alice`, `-backupWebDAVPassword ...`, and
    /// the optional `-backupWebDAVRoot empo`. A second user name or
    /// password for the second server goes in
    /// `-backupWebDAVUser2` and `-backupWebDAVPassword2`.
    private static func addTheWebDAVTargets() async {
        let defaults = UserDefaults.standard
        let addresses = (defaults.string(forKey: "backupWebDAVAddresses") ?? "")
            .split(separator: " ")
            .compactMap { URL(string: String($0)) }
        guard !addresses.isEmpty else {
            log("the WebDAV check needs at least one address")
            return
        }

        for (number, address) in addresses.enumerated() {
            let suffix = number == 0 ? "" : String(number + 1)
            guard
                let user = defaults.string(forKey: "backupWebDAVUser" + suffix)
                    ?? defaults.string(forKey: "backupWebDAVUser"),
                let password = defaults.string(forKey: "backupWebDAVPassword" + suffix)
                    ?? defaults.string(forKey: "backupWebDAVPassword")
            else {
                log("the WebDAV check needs a user name and a password for \(address)")
                continue
            }
            await addOneWebDAVTarget(
                address: address, user: user, password: password, number: number)
        }
    }

    private static func addOneWebDAVTarget(
        address: URL, user: String, password: String, number: Int
    ) async {
        let server = WebDAVServer(address: address, username: user)
        let connection = WebDAVConnection(server: server, password: password)
        if let refusal = server.refusal {
            log("the WebDAV check refuses \(address): \(refusal)")
            return
        }

        let descriptor = TargetDescriptor(
            id: number == 0 ? "webdav" : "webdav-\(number + 1)",
            provider: .webdav,
            label: address.host ?? "WebDAV",
            accountHint: connection.accountHint,
            root: UserDefaults.standard.string(forKey: "backupWebDAVRoot") ?? "")
        do {
            let provider = try WebDAVGate.shared.connect(connection, targetId: descriptor.id)
            await reportThePermissionCheck(descriptor, provider: provider)
            // 9.7 makes the space query a fact about the server. The
            // log names what this one answered, so the check of
            // ticket 012 can read it back.
            let answers = WebDAVGate.shared.target(for: descriptor)?.capabilities.canQueryQuota
            log("the WebDAV server at \(address.host ?? "") reports free space: \(answers ?? false)")
        } catch {
            log("the WebDAV password could not go in the Keychain: \(error)")
        }
    }

    /// Adds the iCloud Drive target and writes each step of the
    /// permission check of 8.7 to the log.
    private static func addTheICloudTarget() async {
        guard let provider = await ICloudDriveGate.shared.target() else {
            log("iCloud is not available on this device")
            return
        }
        await reportThePermissionCheck(
            TargetDescriptor(
                id: "icloud-drive", provider: .iCloudDrive, label: "iCloud Drive",
                accountHint: "this device", root: ICloudDrive.root),
            provider: provider)
    }

    /// Runs the permission check of 8.7 and writes every step to the
    /// log a device check reads.
    private static func reportThePermissionCheck(
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

    private static func log(_ message: String) {
        guard AppSettings.shared.debugLogs else { return }
        BackupLog.line("BackupDeviceCheck", message)
    }
}
