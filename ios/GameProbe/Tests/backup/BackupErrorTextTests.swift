import XCTest

@testable import GameProbe

final class BackupErrorTextTests: XCTestCase {

    func testAWrongKeyNamesTheFieldsToCheck() {
        XCTAssertEqual(
            BackupProviderError.authExpired.line(for: .s3),
            "The access key or the secret key is wrong. Check both and try again.")
        XCTAssertEqual(
            BackupProviderError.authExpired.line(for: .webdav),
            "The user name or the password is wrong. Check both and try again.")
        XCTAssertEqual(
            BackupProviderError.authExpired.line(for: .dropbox),
            "Your Dropbox sign-in expired. Sign in again.")
    }

    func testEveryLineIsASentence() {
        let errors: [BackupProviderError] = [
            .authExpired, .outOfSpace, .throttled(retryAfter: 30), .offline,
            .serverError(status: 500), .permissionDenied, .notFound,
        ]
        for provider in BackupProviderKind.allCases {
            for error in errors {
                let line = error.line(for: provider)
                XCTAssertTrue(line.first?.isUppercase ?? false || line.hasPrefix("iCloud"), line)
                XCTAssertTrue(line.hasSuffix("."), line)
                XCTAssertFalse(line.contains("target"), line)
            }
        }
    }

    func testARefusalKeepsTheServersOwnWords() {
        XCTAssertEqual(
            BackupProviderError.rejected(message: "The bucket refused the request.")
                .line(for: .s3),
            "The bucket refused the request.")
    }

    func testTheCheckNamesTheFailedStepAndTheFix() {
        let result = PermissionCheckResult(
            steps: [
                PermissionCheckStepResult(step: .write, outcome: .failed(.authExpired)),
                PermissionCheckStepResult(step: .list, outcome: .notRun),
                PermissionCheckStepResult(step: .delete, outcome: .notRun),
                PermissionCheckStepResult(step: .freeSpace, outcome: .notRun),
            ], quota: nil)
        XCTAssertEqual(
            result.failureLine(for: .s3),
            "Empo couldn't save a test file. The access key or the secret key is wrong. Check both and try again.")
    }
}
