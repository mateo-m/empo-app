import XCTest

@testable import GameProbe

final class ControlsSchemaTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../..")
            .standardizedFileURL
    }

    private func repoFile(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent(relativePath)
    }

    private func loadRepoData(_ relativePath: String) throws -> Data {
        let url = repoFile(relativePath)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "missing repo file: \(relativePath)"
        )
        return try Data(contentsOf: url)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            XCTFail("expected top-level object")
            return [:]
        }
        return object
    }

    private func stringEnum(at pointer: [String], in root: [String: Any]) -> [String] {
        var current: Any = root
        for key in pointer {
            guard let object = current as? [String: Any], let next = object[key] else {
                XCTFail("missing JSON pointer segment: \(key)")
                return []
            }
            current = next
        }
        guard let schema = current as? [String: Any], let values = schema["enum"] as? [String] else {
            XCTFail("expected string enum at /\(pointer.joined(separator: "/"))")
            return []
        }
        return values
    }

    func testSchemaKeyCodeEnumMatchesKeyCodeTable() throws {
        let data = try loadRepoData("docs/schemas/empo-controls.v1.schema.json")
        let schema = try jsonObject(from: data)
        let schemaCodes = stringEnum(at: ["$defs", "keyCode"], in: schema)
        XCTAssertEqual(schemaCodes, KeyCodeTable.allCodes)
    }

    func testSchemaControllerElementEnumMatchesVocabulary() throws {
        let data = try loadRepoData("docs/schemas/empo-controls.v1.schema.json")
        let schema = try jsonObject(from: data)
        let schemaElements = stringEnum(at: ["$defs", "controllerElement"], in: schema)
        XCTAssertEqual(schemaElements, ControllerElement.allElements)
    }

    func testPublishedExampleParsesWithZeroFindings() throws {
        let data = try loadRepoData("docs/examples/controls.json")
        let result = ControlsManifestLoader.parse(data: data)
        XCTAssertNotNil(result.manifest)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testPublishedExampleMatchesSpecFixture() throws {
        let published = try loadRepoData("docs/examples/controls.json")
        let fixture = try Data(contentsOf: fixtureURL("spec-example.json5"))

        let publishedResult = ControlsManifestLoader.parse(data: published)
        let fixtureResult = ControlsManifestLoader.parse(data: fixture)

        XCTAssertTrue(publishedResult.findings.isEmpty)
        XCTAssertTrue(fixtureResult.findings.isEmpty)
        XCTAssertEqual(publishedResult.manifest, fixtureResult.manifest)
    }

    private func fixtureURL(_ name: String) -> URL {
        #if SWIFT_PACKAGE
        guard let base = Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures/controls/\(name)"),
            FileManager.default.fileExists(atPath: base.path)
        else {
            XCTFail("missing fixture: \(name)")
            return URL(fileURLWithPath: "/")
        }
        return base
        #else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Fixtures/controls/\(name)")
        #endif
    }
}
