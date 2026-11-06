// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class BackupTargetAddTests: XCTestCase {

    func testTheFormShowsTheFolderTheBackupsGoTo() {
        XCTAssertEqual(
            BackupTargetAdd.backupAddress(
                of: .s3,
                form: [
                    "address": "https://127.0.0.1:9443", "bucket": "empo-live", "region": "us-east-1",
                    "root": "demo",
                ]),
            "https://127.0.0.1:9443/empo-live/demo/Empo")
        XCTAssertEqual(
            BackupTargetAdd.backupAddress(
                of: .s3,
                form: ["address": "https://s3.us-east-1.amazonaws.com", "bucket": "my-saves"]),
            "https://my-saves.s3.us-east-1.amazonaws.com/Empo")
        XCTAssertEqual(
            BackupTargetAdd.backupAddress(
                of: .webdav,
                form: [
                    "address": "https://cloud.example.com/remote.php/dav/files/you/", "root": "games saves",
                ]),
            "https://cloud.example.com/remote.php/dav/files/you/games%20saves/Empo")
        XCTAssertNil(BackupTargetAdd.backupAddress(of: .webdav, form: ["address": "cloud.example.com"]))
        XCTAssertNil(BackupTargetAdd.backupAddress(of: .s3, form: [:]))
    }

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
        XCTAssertEqual(
            line, "Empo couldn't reach this address. Check it and your connection, then try again.")
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
