// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import GameProbe
import XCTest

@testable import Empo

/// Runs every operation of `BackupProvider` and a full backup and
/// restore against the real service of each backup location that
/// this Simulator holds.
///
/// A test skips when the Simulator holds no location of its kind. To
/// run one, add the location in Settings > Backups on the Simulator,
/// then run the test on that Simulator. Each test writes only under a
/// new `empo-live-test-<hex>` folder and deletes it at the end.
@MainActor
final class BackupLiveTests: XCTestCase {

    private let fm = FileManager.default
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = fm.temporaryDirectory
            .appendingPathComponent("BackupLiveTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: scratch)
        super.tearDown()
    }

    func testWebDAV() async throws {
        try await runEveryCheck(on: .webdav, bigFileBytes: 40 << 20)
    }

    func testS3() async throws {
        // A multipart upload needs a 5 GiB file at the real limits.
        S3Gate.shared.useSmallParts(singleUploadLimit: 16 << 20, partBase: 16 << 20)
        try await runEveryCheck(on: .s3, bigFileBytes: 40 << 20)
    }

    func testDropbox() async throws {
        // Over `Dropbox.singleUploadLimitBytes`, so the upload session runs.
        try await runEveryCheck(on: .dropbox, bigFileBytes: Dropbox.singleUploadLimitBytes + (1 << 20))
    }

    func testGoogleDrive() async throws {
        try await runEveryCheck(on: .googleDrive, bigFileBytes: 3 * GoogleDrive.uploadChunkBytes + 12345)
    }

    func testICloudDrive() async throws {
        try await runEveryCheck(on: .iCloudDrive, bigFileBytes: 40 << 20)
    }

    /// Needs a TLS server with a self-signed certificate on
    /// 127.0.0.1:9445, for example
    /// `openssl s_server -accept 9445 -cert self.pem -key self.key -www`.
    func testAServerWithAnUntrustedCertificateFailsAtOnce() async throws {
        let outcome = await answer(within: 90) {
            await BackupTargetAdd.webdav(form: [
                "label": "Untrusted", "address": "https://127.0.0.1:9445",
                "username": "tester", "password": "secret",
            ])
        }
        if case .failed(BackupProviderError.offline.line(for: .webdav)) = outcome {
            throw XCTSkip("no TLS server listens on 127.0.0.1:9445")
        }
        guard case .checked(_, let result) = outcome else {
            return XCTFail("the add did not run the check: \(String(describing: outcome))")
        }
        XCTAssertFalse(result.allowsAdd)
        guard case .failed(.rejected(let line)) = result.steps.first?.outcome else {
            return XCTFail("the write step did not fail: \(result)")
        }
        XCTAssertTrue(line.hasSuffix(TransportSecurity.systemTrustMessage), line)
    }

    func testAWrongWebDAVPasswordDoesNotAdd() async throws {
        try await assertAWrongSecretDoesNotAdd(
            .webdav, secretField: "password", fails: .authExpired
        ) {
            await BackupTargetAdd.webdav(form: $0)
        }
    }

    func testAWrongS3SecretDoesNotAdd() async throws {
        // S3 answers a wrong secret with `SignatureDoesNotMatch`.
        try await assertAWrongSecretDoesNotAdd(
            .s3, secretField: "secretAccessKey", fails: .authExpired
        ) {
            await BackupTargetAdd.s3(form: $0)
        }
    }

    /// Needs the WebDAV and S3 servers stopped, and
    /// `TEST_RUNNER_EMPO_SERVERS_DOWN=1` in the environment of
    /// `xcodebuild`.
    func testABackupWhileTheServerIsDownStopsAsOffline() async throws {
        guard ProcessInfo.processInfo.environment["EMPO_SERVERS_DOWN"] == "1" else {
            throw XCTSkip("the servers are up")
        }
        let targets = BackupTargets.load().filter { [.webdav, .s3].contains($0.provider) }
        XCTAssertFalse(targets.isEmpty, "this Simulator holds no WebDAV or S3 location")
        let game = try makeGame()
        for target in targets {
            guard let provider = await BackupTargets.provider(for: target) else {
                XCTFail("\(target.label) does not open")
                continue
            }
            do {
                _ = try await provider.list(prefix: target.root + "/")
                XCTFail("\(target.label) answered a listing with the server down")
            } catch {
                XCTAssertEqual(error as? BackupProviderError, .offline, target.label)
            }
            let localRoot = scratch.appendingPathComponent("local-\(target.id)", isDirectory: true)
            try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
            let engine = SnapshotEngine(
                provider: provider, store: try BackupStateStore(url: nil), localRoot: localRoot)
            let result = await answer(within: 120) {
                await self.backUp(
                    game, with: engine, to: target, namespaceId: UUID().uuidString.lowercased())
            }
            XCTAssertEqual(result?.stop, .offline, "\(target.label): \(String(describing: result))")
        }
    }

    // MARK: - The checks

    /// Adds the saved location of this kind again under a new id, with
    /// a wrong secret.
    private func assertAWrongSecretDoesNotAdd(
        _ kind: BackupProviderKind, secretField: String, fails expected: BackupProviderError,
        _ add: @escaping @MainActor ([String: String]) async -> BackupTargetAdd.Outcome
    ) async throws {
        guard let target = BackupTargets.load().first(where: { $0.provider == kind }) else {
            throw XCTSkip("this Simulator holds no \(kind.rawValue) location")
        }
        var form = BackupTargetAdd.signInForm(of: target)
        form["label"] = "Wrong secret"
        form[secretField] = "not-the-secret"
        let outcome = await answer(within: 90) { await add(form) }
        guard case .checked(let descriptor, let result) = outcome else {
            return XCTFail("the add did not run the check: \(String(describing: outcome))")
        }
        XCTAssertFalse(result.allowsAdd)
        XCTAssertFalse(BackupTargets.load().contains { $0.id == descriptor.id })
        guard case .failed(let error) = result.steps.first?.outcome else {
            return XCTFail("the write step did not fail: \(result)")
        }
        XCTAssertEqual(error, expected)
    }

    private func runEveryCheck(on kind: BackupProviderKind, bigFileBytes: Int64) async throws {
        guard let target = BackupTargets.load().first(where: { $0.provider == kind }) else {
            throw XCTSkip("this Simulator holds no \(kind.rawValue) location")
        }
        guard let provider = await BackupTargets.provider(for: target) else {
            return XCTFail("\(target.label) does not open: is it signed in?")
        }
        let base = BackupNamespacePaths.join(
            target.root, "empo-live-test-\(UUID().uuidString.prefix(8).lowercased())")

        do {
            try await checkTheOperations(provider, base: base, bigFileBytes: bigFileBytes)
            try await checkABackupAndARestore(provider, target: target, base: base)
        } catch {
            XCTFail("\(target.label): \(error)")
        }
        try await provider.deleteEverything(under: base + "/")
        let left: [RemoteObject] = try await provider.list(prefix: base + "/")
        XCTAssertEqual(left.map(\.path), [], "the test folder is not empty after the delete")
    }

    private func checkTheOperations(
        _ provider: any BackupProvider, base: String, bigFileBytes: Int64
    ) async throws {
        let first = path(base, "one/first.txt")
        try await provider.put(localFile: try file(Data("hello".utf8)), path: first)
        try await assertDurable(provider, first)
        try await assertListing(provider, base, contains: [first: 5])
        try await assertContents(provider, first, Data("hello".utf8))

        let longer = Data("hello, a longer second version".utf8)
        try await provider.put(localFile: try file(longer), path: first)
        try await assertContents(provider, first, longer)
        try await assertListing(provider, base, contains: [first: Int64(longer.count)])

        // Game folder names come from the user's files, so they carry
        // accents, other scripts, and URL characters.
        let names = [
            "Pokémon Épée/save #1 & 50% + more's (copy).dat",
            "日本語のゲーム/セーブ01.rxdata",
            "🎮 Game; [v1.2]/a=b?c.sav",
        ]
        var named: [String: Int64] = [:]
        for (index, name) in names.enumerated() {
            let data = Data("save \(index)".utf8)
            try await provider.put(localFile: try file(data), path: path(base, name))
            named[path(base, name)] = Int64(data.count)
        }
        try await assertListing(provider, base, contains: named)
        for (index, name) in names.enumerated() {
            try await assertContents(provider, path(base, name), Data("save \(index)".utf8))
        }

        let empty = path(base, "empty.bin")
        try await provider.put(localFile: try file(Data()), path: empty)
        try await assertContents(provider, empty, Data())

        let big = path(base, "big.bin")
        let bigData = randomData(count: Int(bigFileBytes))
        try await provider.put(localFile: try file(bigData), path: big)
        try await assertDurable(provider, big)
        try await assertListing(provider, base, contains: [big: bigFileBytes])
        try await assertContents(provider, big, bigData)

        let narrow = try await provider.list(prefix: path(base, "one") + "/")
        XCTAssertEqual(narrow.map(\.path), [first], "a prefix does not narrow the listing")

        let parallel = (0..<8).map { path(base, "parallel/\($0).bin") }
        let parallelData = (0..<8).map { _ in randomData(count: 256 * 1024) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (at, data) in zip(parallel, parallelData) {
                let local = try file(data)
                group.addTask { try await provider.put(localFile: local, path: at) }
            }
            try await group.waitForAll()
        }
        for (at, data) in zip(parallel, parallelData) {
            try await assertContents(provider, at, data)
        }

        let missing = path(base, "missing/nothing.bin")
        await assertNotFound("get") {
            try await provider.get(path: missing, localFile: self.scratch.appendingPathComponent("x"))
        }
        await assertNotFound("confirm") { _ = try await provider.confirm(path: missing) }
        try await provider.delete(paths: [missing])

        try await provider.delete(paths: [parallel[0], parallel[1]])
        let afterDelete = try await provider.list(prefix: path(base, "parallel") + "/")
        XCTAssertEqual(Set(afterDelete.map(\.path)), Set(parallel.dropFirst(2)))

        if provider.capabilities.canQueryQuota {
            let quota = try await provider.quota()
            XCTAssertNotNil(quota, "the service says it answers a space query, and it did not")
            XCTAssertGreaterThanOrEqual(quota?.usedBytes ?? -1, 0)
        }
    }

    /// Backs up a game, changes one save, backs up again, then
    /// restores the first snapshot into an empty folder.
    private func checkABackupAndARestore(
        _ provider: any BackupProvider, target: TargetDescriptor, base: String
    ) async throws {
        let game = try makeGame()
        let namespaceId = UUID().uuidString.lowercased()
        let localRoot = scratch.appendingPathComponent("local", isDirectory: true)
        try fm.createDirectory(at: localRoot, withIntermediateDirectories: true)
        var descriptor = target
        descriptor.root = base
        let engine = SnapshotEngine(
            provider: provider, store: try BackupStateStore(url: nil), localRoot: localRoot)
        func run() async -> BackupRunResult {
            await backUp(game, with: engine, to: descriptor, namespaceId: namespaceId)
        }
        let firstRun = await run()
        XCTAssertEqual(firstRun.outcome, .success, "first backup: \(firstRun)")
        guard case .wroteSnapshot(let firstSnapshot) = firstRun.stream(game.identity.gameKey)?.outcome else {
            return XCTFail("the first backup wrote no snapshot: \(firstRun)")
        }

        try randomData(count: 3 << 20).write(
            to: game.container.appendingPathComponent("Game/Save01.rxdata"), options: .atomic)
        let secondRun = await run()
        XCTAssertEqual(secondRun.outcome, .success, "second backup: \(secondRun)")
        XCTAssertEqual(
            secondRun.stream(game.identity.gameKey)?.uploadedBlobCount, 1,
            "the second backup uploaded more than the one changed save")

        try fm.removeItem(at: game.container)
        let restored = await RestoreEngine(
            provider: provider, store: try BackupStateStore(url: nil), localRoot: localRoot
        ).run(
            RestoreRequest(
                targetId: target.id,
                root: base,
                namespaceId: namespaceId,
                stream: BackupStream(key: game.identity.gameKey),
                snapshotId: firstSnapshot,
                scope: .wholeGame,
                destination: MemberSource(container: game.container),
                freeSpaceBytes: .max,
                mode: .full))
        guard case .finished = restored else {
            return XCTFail("the restore did not finish: \(restored)")
        }
        for (relative, data) in game.files {
            let back = try? Data(contentsOf: game.container.appendingPathComponent(relative))
            XCTAssertEqual(back, data, "\(relative) did not come back as it was backed up")
        }
    }

    // MARK: - Helpers

    private struct LiveGame {
        let documents: URL
        let container: URL
        let identity: GameIdentity
        let files: [String: Data]
    }

    private func makeGame() throws -> LiveGame {
        let documents = scratch.appendingPathComponent("Documents", isDirectory: true)
        let folderName = "Live Quest é"
        let game = LiveGame(
            documents: documents,
            container: documents.appendingPathComponent("Games/\(folderName)", isDirectory: true),
            identity: GameIdentity(folderName: folderName),
            files: [
                "Game/Game.ini": Data("[Game]\nTitle=Live Quest\n".utf8),
                "Game/Save01.rxdata": randomData(count: 3 << 20),
                "Game/Saves/autosave.sav": randomData(count: 4096),
                "Metadata/metadata.json": Data("{\"title\":\"Live Quest\"}".utf8),
            ])
        try writeTree(game.files, into: game.container)
        return game
    }

    private func backUp(
        _ game: LiveGame, with engine: SnapshotEngine, to descriptor: TargetDescriptor,
        namespaceId: String
    ) async -> BackupRunResult {
        await engine.run(
            BackupRunRequest(
                runId: UUID().uuidString,
                descriptor: descriptor,
                namespaceId: namespaceId,
                deviceId: "live-test-device",
                deviceName: "Live test",
                games: [
                    BackupRunGame(
                        identity: game.identity,
                        set: GameBackupSetRequest(
                            containerURL: game.container, mode: .full,
                            documentsRoot: game.documents))
                ]))
    }

    private func path(_ base: String, _ relative: String) -> String {
        BackupNamespacePaths.join(base, relative)
    }

    private func file(_ data: Data) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 0, to: count, by: 8) {
                var word = generator.next()
                withUnsafeBytes(of: &word) { word in
                    let length = min(8, count - offset)
                    bytes.baseAddress!.advanced(by: offset)
                        .copyMemory(from: word.baseAddress!, byteCount: length)
                }
            }
        }
        return data
    }

    private func writeTree(_ files: [String: Data], into root: URL) throws {
        for (relative, data) in files {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    /// iCloud Drive confirms later, so a pending answer turns into a
    /// confirmed one within the wait.
    private func assertDurable(_ provider: any BackupProvider, _ at: String) async throws {
        for _ in 0..<60 {
            if try await provider.confirm(path: at) == .confirmed { return }
            try await Task.sleep(for: .seconds(2))
        }
        XCTFail("\(at) is still not durable after 2 minutes")
    }

    private func assertListing(
        _ provider: any BackupProvider, _ base: String, contains expected: [String: Int64],
        line: UInt = #line
    ) async throws {
        let listed = try await provider.list(prefix: base + "/")
        let sizes = Dictionary(listed.map { ($0.path, $0.sizeBytes) }, uniquingKeysWith: { $1 })
        for (at, size) in expected {
            XCTAssertEqual(
                sizes[at], size,
                "the listing has \(at) as \(String(describing: sizes[at])); "
                    + "it holds \(sizes.keys.sorted())", line: line)
        }
    }

    private func assertContents(
        _ provider: any BackupProvider, _ at: String, _ expected: Data, line: UInt = #line
    ) async throws {
        let local = scratch.appendingPathComponent(UUID().uuidString)
        try await provider.get(path: at, localFile: local)
        let data = try Data(contentsOf: local)
        XCTAssertEqual(data.count, expected.count, "\(at) came back with another size", line: line)
        XCTAssertTrue(data == expected, "\(at) came back with other bytes", line: line)
    }

    private func assertNotFound(
        _ what: String, _ operation: () async throws -> Void, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("\(what) of a missing path did not fail", line: line)
        } catch let error as BackupProviderError {
            XCTAssertEqual(error, .notFound, "\(what) of a missing path", line: line)
        } catch {
            XCTFail("\(what) of a missing path: \(error)", line: line)
        }
    }
}
