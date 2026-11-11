import GameProbe
import XCTest

@testable import Empo

final class SyncRemoteTests: XCTestCase {

    private struct FolderProvider: BackupProvider {
        let files: [String: Data]
        let capabilities = TargetCapabilities()

        func list(prefix: String) async throws(BackupProviderError) -> [RemoteObject] {
            files.keys.filter { $0.hasPrefix(prefix) }.sorted().map {
                RemoteObject(path: $0, sizeBytes: Int64(files[$0]?.count ?? 0), modifiedAt: nil)
            }
        }

        func get(path: String, localFile: URL) async throws(BackupProviderError) {
            guard let data = files[path] else { throw .notFound }
            do {
                try data.write(to: localFile)
            } catch {
                throw .rejected(message: "\(error)")
            }
        }

        func put(localFile: URL, path: String) async throws(BackupProviderError) {}
        func confirm(path: String) async throws(BackupProviderError) -> PutConfirmation { .confirmed }
        func delete(paths: [String]) async throws(BackupProviderError) {}
        func quota() async throws(BackupProviderError) -> QuotaReading? { nil }
    }

    func testADamagedDeviceRecordHidesOnlyItsOwnDevice() async throws {
        var files: [String: Data] = [:]
        for id in ["first", "second"] {
            let paths = BackupNamespacePaths(root: "Empo", namespaceId: id)
            files[paths.deviceFile] = try DeviceRecord(
                deviceId: id, model: "iPad", name: id, lastWriteAt: .now, syncGroupId: "g1"
            ).jsonData()
            files[paths.syncDocumentFile] = Data("copy".utf8)
        }
        let damaged = BackupNamespacePaths(root: "Empo", namespaceId: "damaged")
        files[damaged.deviceFile] = Data("{ this is not json".utf8)
        files[damaged.syncDocumentFile] = Data("copy".utf8)

        let listed = await SyncRemote.namespaces(root: "Empo", provider: FolderProvider(files: files))
        let namespaces = try XCTUnwrap(listed)

        XCTAssertEqual(namespaces.map(\.id), ["damaged", "first", "second"])
        XCTAssertNil(namespaces[0].record)
        XCTAssertNotNil(namespaces[0].document)
        XCTAssertEqual(namespaces[1].record?.syncGroupId, "g1")
        XCTAssertEqual(namespaces[2].record?.syncGroupId, "g1")
    }
}
