import Foundation
import GameProbe
import UIKit

/// The add flow of SPEC 13.7.
///
/// Each entry point signs in or takes the connection the user typed,
/// then hands the target to the permission check of 8.7. Nothing
/// here draws. `AddTargetSheet` and `PermissionCheckSheet` do.
@MainActor
enum BackupTargetAdd {

    enum Outcome {
        /// The check ran. `result.allowsAdd` says whether the target
        /// joined the list.
        case checked(TargetDescriptor, PermissionCheckResult)
        /// The user closed the browser.
        case cancelled
        case failed(String)

        var addedTheLocation: Bool {
            if case .checked(_, let result) = self { return result.allowsAdd }
            return false
        }
    }

    static func iCloud() async -> Outcome {
        let descriptor = TargetDescriptor(
            id: "icloud-drive",
            provider: .iCloudDrive,
            label: "iCloud Drive",
            accountHint: String(localized: "this device"),
            root: ICloudDrive.root)
        guard let provider = await ICloudDriveGate.shared.target() else {
            return .failed(await iCloudClosedLine(descriptor))
        }
        return await check(descriptor, provider: provider)
    }

    private static func iCloudClosedLine(_ target: TargetDescriptor) async -> String {
        TargetRowRules.stateLine(
            .cannotOpen(await ICloudDriveGate.shared.availability().reach), target: target)
    }

    static func dropbox(presenting screen: UIViewController) async -> Outcome {
        guard DropboxSignIn.isConfigured else {
            return .failed(String(localized: "Dropbox isn't available in this version of Empo."))
        }
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .dropbox,
            label: "Dropbox",
            accountHint: String(localized: "this account"),
            root: Dropbox.root)
        do {
            guard
                try await DropboxGate.shared.signIn(
                    targetId: descriptor.id, presenting: screen)
            else { return .cancelled }
        } catch {
            return .failed(signInFailure(error, provider: .dropbox))
        }
        guard let provider = DropboxGate.shared.target(for: descriptor) else {
            putBack(nil, targetId: descriptor.id)
            return .failed(openFailedLine)
        }
        return await check(descriptor, provider: provider, secretBefore: nil)
    }

    static func googleDrive(presenting screen: UIViewController) async -> Outcome {
        guard GoogleDriveSignIn.isConfigured else {
            return .failed(String(localized: "Google Drive isn't available in this version of Empo."))
        }
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .googleDrive,
            label: "Google Drive",
            accountHint: String(localized: "this account"),
            root: GoogleDrive.root)
        do {
            guard
                try await GoogleDriveGate.shared.signIn(
                    targetId: descriptor.id, presenting: screen)
            else { return .cancelled }
        } catch {
            return .failed(signInFailure(error, provider: .googleDrive))
        }
        guard let provider = GoogleDriveGate.shared.target(for: descriptor) else {
            putBack(nil, targetId: descriptor.id)
            return .failed(openFailedLine)
        }
        return await check(descriptor, provider: provider, secretBefore: nil)
    }

    /// `id` is the target that signs in again. A new target takes a
    /// fresh id.
    /// A sign-in passes the `existing` target, which keeps its id,
    /// its folder, and its backup policy.
    static func s3(form: [String: String], existing: TargetDescriptor? = nil) async -> Outcome {
        guard let bucket = s3Bucket(form: form) else {
            return .failed(String(localized: "Enter the address."))
        }
        let address = bucket.address
        if let refusal = bucket.refusal { return .failed(line(of: refusal)) }
        let connection = S3Connection(
            bucket: bucket,
            credentials: S3SigV4.Credentials(
                accessKeyId: form["accessKeyId"] ?? "",
                secretAccessKey: form["secretAccessKey"] ?? ""))
        var descriptor =
            existing
            ?? TargetDescriptor(
                id: UUID().uuidString, provider: .s3, label: "", root: form["root"] ?? "")
        descriptor.label = form["label"] ?? bucket.name
        descriptor.accountHint = connection.accountHint
        do {
            let before = try BackupKeychain.secret(targetId: descriptor.id)
            let provider = try S3Gate.shared.connect(connection, targetId: descriptor.id)
            await LocalNetworkAccess.waitForTheAnswer(to: address)
            return await check(descriptor, provider: provider, secretBefore: before)
        } catch {
            return .failed(keychainFailedLine)
        }
    }

    private static func s3Bucket(form: [String: String]) -> S3Bucket? {
        URL(string: form["address"] ?? "").map {
            S3Bucket(
                address: $0,
                region: form["region"] ?? "",
                name: form["bucket"] ?? "",
                usesPathStyle: isOn("usesPathStyle", in: form))
        }
    }

    private static func webdavServer(form: [String: String]) -> WebDAVServer? {
        URL(string: form["address"] ?? "").map {
            WebDAVServer(address: $0, username: form["username"] ?? "")
        }
    }

    /// The Empo folder the form would back up to, or nil while the
    /// address has no host.
    static func backupAddress(of service: BackupProviderKind, form: [String: String]) -> String? {
        let folder = BackupNamespacePaths.join(
            form["root"] ?? "", BackupNamespacePaths.empoDirectoryName)
        switch service {
        case .s3: return s3Bucket(form: form)?.url(key: folder)?.absoluteString
        case .webdav: return webdavServer(form: form)?.url(path: folder)?.absoluteString
        case .iCloudDrive, .dropbox, .googleDrive: return nil
        }
    }

    /// A toggle the user did not touch reads as the default of its
    /// service.
    static func isOn(_ toggle: String, in form: [String: String]) -> Bool {
        if let value = form[toggle] { return value == "true" }
        guard toggle == "usesPathStyle", let address = URL(string: form["address"] ?? "") else {
            return false
        }
        return S3Bucket.prefersPathStyle(address: address)
    }

    static func webdav(form: [String: String], existing: TargetDescriptor? = nil) async -> Outcome {
        guard let server = webdavServer(form: form) else {
            return .failed(String(localized: "Enter the address."))
        }
        let address = server.address
        if let refusal = server.refusal { return .failed(line(of: refusal)) }
        let connection = WebDAVConnection(server: server, password: form["password"] ?? "")
        var descriptor =
            existing
            ?? TargetDescriptor(
                id: UUID().uuidString, provider: .webdav, label: "", root: form["root"] ?? "")
        descriptor.label = form["label"] ?? address.host ?? "WebDAV"
        descriptor.accountHint = connection.accountHint
        do {
            let before = try BackupKeychain.secret(targetId: descriptor.id)
            let provider = try WebDAVGate.shared.connect(connection, targetId: descriptor.id)
            await LocalNetworkAccess.waitForTheAnswer(to: address)
            return await check(descriptor, provider: provider, secretBefore: before)
        } catch {
            return .failed(keychainFailedLine)
        }
    }

    /// The typed services have no browser. Their sign-in is the add
    /// form again, per 8.8, with the secret left out.
    static func signsInThroughTheForm(_ kind: BackupProviderKind) -> Bool {
        switch kind {
        case .s3, .webdav: return true
        case .iCloudDrive, .dropbox, .googleDrive: return false
        }
    }

    /// What the sign-in form starts with. A placeholder of 8.8 knows
    /// its label and its root only, and a target that lost its
    /// password still knows its address and its user name.
    /// A new place under the same target id would reuse the upload
    /// cache of the old one, so a sign-in cannot change these.
    static let locationFields: Set<String> = [
        "address", "bucket", "region", "root", "usesPathStyle", "username",
    ]

    static func signInForm(of target: TargetDescriptor) -> [String: String] {
        var values = ["label": target.label, "root": target.root]
        switch target.provider {
        case .webdav:
            if let connection = BackupKeychain.secret(WebDAVConnection.self, targetId: target.id) {
                values["address"] = connection.server.address.absoluteString
                values["username"] = connection.server.username
            }
        case .s3:
            if let connection = BackupKeychain.secret(S3Connection.self, targetId: target.id) {
                values["address"] = connection.bucket.address.absoluteString
                values["bucket"] = connection.bucket.name
                values["region"] = connection.bucket.region
                values["accessKeyId"] = connection.credentials.accessKeyId
                values["usesPathStyle"] = connection.bucket.usesPathStyle ? "true" : "false"
            }
        case .iCloudDrive, .dropbox, .googleDrive:
            break
        }
        return values
    }

    /// Signs in again to a browser or iCloud target, then runs the
    /// same check, per 13.7. The typed services go through
    /// `signInForm` and the form instead.
    static func signInAgain(_ target: TargetDescriptor) async -> Outcome {
        switch target.provider {
        case .iCloudDrive:
            guard let provider = await ICloudDriveGate.shared.target() else {
                return .failed(await iCloudClosedLine(target))
            }
            return await check(target, provider: provider)
        case .dropbox, .googleDrive:
            guard let screen = await OAuthSignIn.screenForTheSheet() else {
                return .failed(noSignInScreenLine)
            }
            let before: String?
            do {
                before = try BackupKeychain.secret(targetId: target.id)
            } catch {
                return .failed(keychainFailedLine)
            }
            do {
                let signedIn =
                    target.provider == .dropbox
                    ? try await DropboxGate.shared.signIn(
                        targetId: target.id, presenting: screen)
                    : try await GoogleDriveGate.shared.signIn(
                        targetId: target.id, presenting: screen)
                guard signedIn else { return .cancelled }
            } catch {
                return .failed(signInFailure(error, provider: target.provider))
            }
            guard let provider = await BackupTargets.provider(for: target) else {
                putBack(before, targetId: target.id)
                return .failed(openFailedLine)
            }
            return await check(target, provider: provider, secretBefore: before)
        case .s3, .webdav:
            return .failed(String(localized: "Enter the password for this location again."))
        }
    }

    /// Checks a target whose secret this flow just wrote. A location
    /// that did not join gets back the secret it had before, or none.
    private static func check(
        _ descriptor: TargetDescriptor, provider: some BackupProvider, secretBefore: String?
    ) async -> Outcome {
        let outcome = await check(descriptor, provider: provider)
        if !outcome.addedTheLocation { putBack(secretBefore, targetId: descriptor.id) }
        return outcome
    }

    private static func putBack(_ secret: String?, targetId: String) {
        BackupTargets.forget(targetId: targetId)
        do {
            if let secret {
                try BackupKeychain.setSecret(secret, targetId: targetId)
            } else {
                try BackupKeychain.removeSecret(targetId: targetId)
            }
        } catch {
            BackupLog.line("BackupTargetAdd", "The secret of \(targetId) was not put back: \(error)")
        }
    }

    private static func check(
        _ descriptor: TargetDescriptor, provider: some BackupProvider
    ) async -> Outcome {
        var descriptor = descriptor
        if let account = await (provider as? any AccountReading)?.account() {
            descriptor.take(account)
        }
        // The probe upload goes through the background session, which
        // retries a host that does not answer for up to 7 days. A
        // mistyped address must fail here, while the user waits.
        if signsInThroughTheForm(descriptor.provider) {
            do {
                _ = try await provider.list(
                    prefix: PermissionCheck.makeProbePath(root: descriptor.root))
            } catch {
                if case .offline = error {
                    return .failed(BackupProviderError.offline.line(for: descriptor.provider))
                }
            }
        }
        let result: PermissionCheckResult
        do {
            result = try await BackupTargets.addAfterPermissionCheck(descriptor, provider: provider)
        } catch {
            BackupLog.line("BackupTargetAdd", "The check of \(descriptor.label) failed: \(error)")
            return .failed(String(localized: "Empo couldn't check this location. Try again."))
        }
        do {
            let store = try BackupRoot.openStateStore()
            defer { store.close() }
            try store.recordTargetQuota(targetId: descriptor.id, reading: result.quota)
            if result.allowsAdd {
                try store.recordTargetFailure(targetId: descriptor.id, failure: nil, at: Date())
            }
        } catch {
            BackupLog.line("BackupTargetAdd", "The check of \(descriptor.label) was not recorded: \(error)")
        }
        return .checked(descriptor, result)
    }

    private static func line(of error: BackupProviderError) -> String {
        switch error {
        case .rejected(let message): return message
        default: return String(localized: "Empo can't use this address. Check it and try again.")
        }
    }

    private static func signInFailure(_ error: Error, provider: BackupProviderKind) -> String {
        switch error {
        case let error as BackupProviderError: return error.line(for: provider)
        case is BackupKeychain.Failure: return keychainFailedLine
        default: return String(localized: "Empo couldn't finish the sign-in. Try again.")
        }
    }

    static let noSignInScreenLine = String(localized: "Empo couldn't show the sign-in page. Try again.")
    private static let openFailedLine = String(
        localized: "Empo couldn't open this location after you signed in. Try again.")
    private static let keychainFailedLine = String(
        localized: "Empo couldn't save the sign-in on this device. Try again.")
}
