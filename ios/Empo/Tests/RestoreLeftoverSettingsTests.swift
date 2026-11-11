// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

@MainActor
final class RestoreLeftoverSettingsTests: XCTestCase {

    private var saved: Data?

    override func setUp() async throws {
        try await super.setUp()
        XCTAssertTrue(BackupRoot.prepare())
        saved = try? Data(contentsOf: PreferenceRestore.restoredFile)
    }

    override func tearDown() async throws {
        if let saved {
            try? saved.write(to: PreferenceRestore.restoredFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: PreferenceRestore.restoredFile)
        }
        try await super.tearDown()
    }

    func testASettingsRestoreAfterAStoppedOneDownloadsTheSettingsFileAgain() async throws {
        let leftover = Data("{\"values\":{}}".utf8)
        try leftover.write(to: PreferenceRestore.restoredFile)
        let manifest = SnapshotManifest(
            mode: .full, containerFolderName: "",
            entries: [
                SnapshotManifest.Entry(
                    root: .preferences, path: PreferencesMemberPath.userDefaultsExportName,
                    size: Int64(leftover.count), modifiedAt: Date(),
                    hash: try ContentHash.hexOfFile(at: PreferenceRestore.restoredFile),
                    compression: .zlib)
            ])

        let files = await RestoreCoordinator.localFilesForTheRestore(
            of: .preferences,
            destination: RestoreCoordinator.destination(for: nil, manifest: manifest),
            manifest: manifest, scope: .preferences)

        XCTAssertFalse(
            files.contains { $0.path == PreferencesMemberPath.userDefaultsExportName },
            "A listed leftover with the same bytes makes the plan skip the download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PreferenceRestore.restoredFile.path))
    }
}
