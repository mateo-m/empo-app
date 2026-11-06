import Foundation

extension BackupProviderError {

    /// The sentence a screen shows for this error on one service,
    /// with the fix where the user has one.
    public func line(for provider: BackupProviderKind) -> String {
        let service = provider.serviceName
        switch self {
        case .authExpired:
            switch provider {
            case .s3:
                return screenText("The access key or the secret key is wrong. Check both and try again.")
            case .webdav:
                return screenText("The user name or the password is wrong. Check both and try again.")
            case .iCloudDrive:
                return screenText("Sign in to iCloud in the Settings app, then try again.")
            case .dropbox, .googleDrive:
                return screenText("Your %@ sign-in expired. Sign in again.", service)
            }
        case .permissionDenied:
            switch provider {
            case .s3:
                return screenText("This key can't write to the bucket. Give it the rights to read, write, and delete files.")
            case .webdav:
                return screenText("This account can't write to that folder. Check its rights on the server.")
            case .iCloudDrive:
                return screenText("Empo can't write to iCloud Drive. Turn on iCloud Drive for Empo in the Settings app.")
            case .dropbox, .googleDrive:
                return screenText("Empo can't write to its %@ folder. Sign in again and allow all the access Empo asks for.", service)
            }
        case .outOfSpace:
            return screenText("%@ is full. Make space, then try again.", service)
        case .offline:
            switch provider {
            case .s3, .webdav:
                return screenText("Empo couldn't reach this address. Check it and your connection, then try again.")
            case .iCloudDrive, .dropbox, .googleDrive:
                return screenText("Empo couldn't reach %@. Check your connection, then try again.", service)
            }
        case .serverError:
            return screenText("The server had an error. Try again later.")
        case .throttled:
            return screenText("%@ is busy. Try again in a few minutes.", service)
        case .notFound:
            switch provider {
            case .s3:
                return screenText("Empo couldn't find the bucket. Check its name and region.")
            case .webdav:
                return screenText("Empo couldn't find that folder on the server. Check the address.")
            case .iCloudDrive, .dropbox, .googleDrive:
                return screenText("Empo couldn't find its folder on %@. Try again.", service)
            }
        case .rejected(let message):
            return message
        }
    }
}

extension PermissionCheckResult {

    /// What the add form shows when the check stops it: the step that
    /// failed, then why.
    public func failureLine(for provider: BackupProviderKind) -> String? {
        guard let failedStep, let failure else { return nil }
        return "\(failedStep.failedLine) \(failure.line(for: provider))"
    }
}

extension PermissionCheckStep {

    var failedLine: String {
        switch self {
        case .write: return screenText("Empo couldn't save a test file.")
        case .list: return screenText("Empo couldn't find the test file it saved.")
        case .delete: return screenText("Empo couldn't delete the test file it saved.")
        case .freeSpace: return screenText("Empo couldn't read the free space.")
        }
    }
}
