import Foundation
import XCTest

@testable import GameProbe

final class OAuthRefreshTests: XCTestCase {

    private func body(_ error: String) -> Data {
        Data(#"{"error": "\#(error)", "error_description": "refresh token is invalid or revoked"}"#.utf8)
    }

    func testARevokedRefreshTokenNeedsASignIn() {
        for kind in [BackupProviderKind.dropbox, .googleDrive] {
            for status in [400, 401] {
                XCTAssertEqual(
                    OAuthRefresh.error(
                        kind: kind, status: status, body: body("invalid_grant"), retryAfterHeader: nil),
                    .authExpired, "\(kind) \(status)")
            }
        }
    }

    func testAnOutageIsRetriedAndNotASignIn() {
        for status in [500, 502, 503] {
            XCTAssertEqual(
                OAuthRefresh.error(kind: .dropbox, status: status, body: Data(), retryAfterHeader: nil),
                .serverError(status: status))
        }
    }

    func testAThrottleWaitsForTheStatedTime() {
        XCTAssertEqual(
            OAuthRefresh.error(kind: .googleDrive, status: 429, body: Data(), retryAfterHeader: "30"),
            .throttled(retryAfter: 30))
        XCTAssertEqual(
            OAuthRefresh.error(kind: .dropbox, status: 429, body: Data(), retryAfterHeader: nil),
            .throttled(retryAfter: Dropbox.defaultRetryAfter))
    }

    func testAnotherRefusalIsNotASignIn() {
        let error = OAuthRefresh.error(
            kind: .dropbox, status: 400, body: body("invalid_request"), retryAfterHeader: nil)
        XCTAssertNotEqual(error, .authExpired)
        XCTAssertEqual(
            error.runStop,
            .rejected(
                message: "Dropbox refused the request. It said: “refresh token is invalid or revoked”"))
    }
}
