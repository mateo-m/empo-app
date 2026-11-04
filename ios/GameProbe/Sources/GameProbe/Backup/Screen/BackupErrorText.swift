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
                return "The access key or the secret key is wrong. Check both and try again."
            case .webdav, .sftp:
                return "The user name or the password is wrong. Check both and try again."
            case .iCloudDrive:
                return "Sign in to iCloud in the Settings app, then try again."
            case .dropbox, .googleDrive:
                return "Your \(service) sign-in expired. Sign in again."
            }
        case .permissionDenied:
            switch provider {
            case .s3:
                return "This key can't write to the bucket. Give it the rights to read, write, and delete files."
            case .webdav, .sftp:
                return "This account can't write to that folder. Check its rights on the server."
            case .iCloudDrive:
                return "Empo can't write to iCloud Drive. Turn on iCloud Drive for Empo in the Settings app."
            case .dropbox, .googleDrive:
                return "Empo can't write to its \(service) folder. Sign in again and allow all the access Empo asks for."
            }
        case .outOfSpace:
            return "\(service) is full. Make space, then try again."
        case .offline:
            switch provider {
            case .s3, .webdav, .sftp:
                return "Empo couldn't reach this address. Check it and your connection, then try again."
            case .iCloudDrive, .dropbox, .googleDrive:
                return "Empo couldn't reach \(service). Check your connection, then try again."
            }
        case .serverError:
            return "The server had an error. Try again later."
        case .throttled:
            return "\(service) is busy. Try again in a few minutes."
        case .notFound:
            switch provider {
            case .s3:
                return "Empo couldn't find the bucket. Check its name and region."
            case .webdav, .sftp:
                return "Empo couldn't find that folder on the server. Check the address."
            case .iCloudDrive, .dropbox, .googleDrive:
                return "Empo couldn't find its folder on \(service). Try again."
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
        case .write: return "Empo couldn't save a test file."
        case .list: return "Empo couldn't find the test file it saved."
        case .delete: return "Empo couldn't delete the test file it saved."
        case .freeSpace: return "Empo couldn't read the free space."
        }
    }
}
