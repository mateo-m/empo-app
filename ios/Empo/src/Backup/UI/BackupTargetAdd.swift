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
    }

    /// The services the add sheet offers, with iCloud under the
    /// runtime gate of 9.1.
    static func offeredServices(iCloudReach: TargetReach) -> [BackupProviderKind] {
        var services: [BackupProviderKind] = [.dropbox, .googleDrive, .s3, .webdav]
        switch iCloudReach {
        case .open, .notInThisBuild:
            services.insert(.iCloudDrive, at: 0)
        case .accountOff:
            // Hidden while the probe answers nil, per 9.1. A
            // configured target keeps its row either way.
            break
        }
        return services
    }

    static func iCloud() async -> Outcome {
        guard let provider = await ICloudDriveGate.shared.target() else {
            return .failed(TargetRowRules.iCloudOffLine)
        }
        return await check(
            TargetDescriptor(
                id: "icloud-drive",
                provider: .iCloudDrive,
                label: "iCloud Drive",
                accountHint: "this device",
                root: ICloudDrive.root),
            provider: provider)
    }

    static func dropbox(presenting screen: UIViewController) async -> Outcome {
        guard DropboxSignIn.isConfigured else {
            return .failed("This build carries no Dropbox app key.")
        }
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .dropbox,
            label: "Dropbox",
            accountHint: "this account",
            root: Dropbox.root)
        do {
            guard
                try await DropboxGate.shared.signIn(
                    targetId: descriptor.id, presenting: screen)
            else { return .cancelled }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let provider = DropboxGate.shared.target(for: descriptor) else {
            return .failed("Dropbox signed in and still cannot open.")
        }
        return await check(descriptor, provider: provider)
    }

    static func googleDrive(presenting screen: UIViewController) async -> Outcome {
        guard GoogleDriveSignIn.isConfigured else {
            return .failed("This build carries no Google Drive client id.")
        }
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .googleDrive,
            label: "Google Drive",
            accountHint: "this account",
            root: GoogleDrive.root)
        do {
            guard
                try await GoogleDriveGate.shared.signIn(
                    targetId: descriptor.id, presenting: screen)
            else { return .cancelled }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let provider = GoogleDriveGate.shared.target(for: descriptor) else {
            return .failed("Google Drive signed in and still cannot open.")
        }
        return await check(descriptor, provider: provider)
    }

    static func s3(form: [String: String]) async -> Outcome {
        guard let address = URL(string: form["address"] ?? "") else {
            return .failed("Type the address of the service.")
        }
        let bucket = S3Bucket(
            address: address,
            region: form["region"] ?? "",
            name: form["bucket"] ?? "",
            usesPathStyle: form["usesPathStyle"] == "true")
        if let refusal = bucket.refusal { return .failed(line(of: refusal)) }
        let connection = S3Connection(
            bucket: bucket,
            credentials: S3SigV4.Credentials(
                accessKeyId: form["accessKeyId"] ?? "",
                secretAccessKey: form["secretAccessKey"] ?? ""))
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .s3,
            label: form["label"] ?? bucket.name,
            accountHint: connection.accountHint,
            root: form["root"] ?? "")
        do {
            let provider = try S3Gate.shared.connect(connection, targetId: descriptor.id)
            return await check(descriptor, provider: provider)
        } catch {
            return .failed("The access key could not go in the Keychain.")
        }
    }

    static func webdav(form: [String: String]) async -> Outcome {
        guard let address = URL(string: form["address"] ?? "") else {
            return .failed("Type the address of the server.")
        }
        let server = WebDAVServer(address: address, username: form["username"] ?? "")
        if let refusal = server.refusal { return .failed(line(of: refusal)) }
        let connection = WebDAVConnection(server: server, password: form["password"] ?? "")
        let descriptor = TargetDescriptor(
            id: UUID().uuidString,
            provider: .webdav,
            label: form["label"] ?? address.host ?? "WebDAV",
            accountHint: connection.accountHint,
            root: form["root"] ?? "")
        do {
            let provider = try WebDAVGate.shared.connect(connection, targetId: descriptor.id)
            return await check(descriptor, provider: provider)
        } catch {
            return .failed("The password could not go in the Keychain.")
        }
    }

    /// Signs in again to a target that already exists, then runs the
    /// same check, per 13.7.
    static func signInAgain(_ target: TargetDescriptor) async -> Outcome {
        switch target.provider {
        case .iCloudDrive:
            return await iCloud()
        case .dropbox, .googleDrive:
            guard let screen = await OAuthSignIn.screenForTheSheet() else {
                return .failed("Empo found no screen to sign in from.")
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
                return .failed(error.localizedDescription)
            }
            guard let provider = await BackupTargets.provider(for: target) else {
                return .failed("The service signed in and still cannot open.")
            }
            return await check(target, provider: provider)
        case .s3, .webdav, .sftp:
            // The secret is typed and not granted, so the target
            // opens with what the Keychain already holds.
            guard let provider = await BackupTargets.provider(for: target) else {
                return .failed("Type the password of this target again to use it.")
            }
            return await check(target, provider: provider)
        }
    }

    private static func check(
        _ descriptor: TargetDescriptor, provider: some BackupProvider
    ) async -> Outcome {
        guard
            let result = try? await BackupTargets.addAfterPermissionCheck(
                descriptor, provider: provider)
        else {
            return .failed("The permission check could not run.")
        }
        if let store = try? BackupStateStore(url: BackupRoot.stateDatabase) {
            try? store.recordTargetQuota(
                targetId: descriptor.id, reading: result.quota, at: Date())
            if result.allowsAdd {
                try? store.recordTargetFailure(
                    targetId: descriptor.id, failure: nil, at: Date())
            }
            store.close()
        }
        return .checked(descriptor, result)
    }

    private static func line(of error: BackupProviderError) -> String {
        switch error {
        case .rejected(let message): return message
        default: return "Empo cannot use this address."
        }
    }
}
