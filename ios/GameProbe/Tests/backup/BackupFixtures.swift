import Foundation
import XCTest

/// Loads a file from `Tests/Fixtures/backup/`, the way the controls
/// fixtures load.
enum BackupFixtures {

    static func url(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) -> URL {
        #if SWIFT_PACKAGE
        guard
            let base = Bundle.module.resourceURL?
                .appendingPathComponent("Fixtures/backup/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        else {
            XCTFail("missing fixture: \(name)", file: file, line: line)
            return URL(fileURLWithPath: "/")
        }
        return base
        #else
        let bundle = Bundle(for: BackupFixtureAnchor.self)
        if let base = bundle.resourceURL?
            .appendingPathComponent("Fixtures/backup/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        {
            return base
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/backup/\(name)")
        #endif
    }

    static func data(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        try Data(contentsOf: url(name, file: file, line: line))
    }
}

/// Only there to give `Bundle(for:)` a class in the test bundle.
final class BackupFixtureAnchor {}
