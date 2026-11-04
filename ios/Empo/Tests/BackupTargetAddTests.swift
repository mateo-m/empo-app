// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class BackupTargetAddTests: XCTestCase {

    func testTheS3FormPutsTheBucketInThePathForEveryHostButAmazon() {
        XCTAssertTrue(
            BackupTargetAdd.isOn("usesPathStyle", in: ["address": "https://127.0.0.1:9443"]))
        XCTAssertTrue(
            BackupTargetAdd.isOn("usesPathStyle", in: ["address": "https://minio.example.com"]))
        XCTAssertFalse(
            BackupTargetAdd.isOn(
                "usesPathStyle", in: ["address": "https://s3.eu-west-1.amazonaws.com"]))
        XCTAssertFalse(
            BackupTargetAdd.isOn(
                "usesPathStyle",
                in: ["address": "https://minio.example.com", "usesPathStyle": "false"]))
        XCTAssertTrue(
            BackupTargetAdd.isOn(
                "usesPathStyle",
                in: ["address": "https://s3.amazonaws.com", "usesPathStyle": "true"]))
    }

    func testAnAddressWithAHostThatDoesNotExistFailsAtOnce() async {
        let outcome = await answer(within: 90) {
            await BackupTargetAdd.s3(form: [
                "label": "Typo", "address": "https://no-such-host.invalid",
                "bucket": "saves", "region": "us-east-1",
                "accessKeyId": "key", "secretAccessKey": "secret",
            ])
        }
        guard case .failed(let line) = outcome else {
            return XCTFail("the add did not fail: \(String(describing: outcome))")
        }
        XCTAssertEqual(line, "Empo could not reach this address. Check it and try again.")
    }
}

extension XCTestCase {

    /// Gives nil when the work does not answer in time.
    @MainActor func answer<Answer>(
        within seconds: TimeInterval, _ work: @escaping @MainActor () async -> Answer
    ) async -> Answer? {
        let answered = expectation(description: "the work answers")
        var answer: Answer?
        Task {
            answer = await work()
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: seconds)
        return answer
    }
}
