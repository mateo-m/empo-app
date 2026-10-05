import XCTest

@testable import Empo

final class DataDirectoryTests: XCTestCase {
    private var folder: URL!
    private var documents: URL!
    private var group: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("DataDirectoryTests-\(UUID().uuidString)")
        documents = folder.appendingPathComponent("Documents", isDirectory: true)
        group = folder.appendingPathComponent("Group", isDirectory: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: group.path)
        try FileManager.default.removeItem(at: folder)
    }

    func testItemThatCannotMoveBackKeepsItsLink() throws {
        let fm = FileManager.default
        let games = group.appendingPathComponent("Games", isDirectory: true)
        try fm.createDirectory(at: games, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: games.appendingPathComponent("save.rxdata"))
        try fm.createSymbolicLink(
            at: documents.appendingPathComponent("Games"), withDestinationURL: games)
        // A folder that the app cannot write makes the move fail.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: group.path)

        DataDirectory.moveItems(backFrom: group, to: documents)

        let save = documents.appendingPathComponent("Games/save.rxdata")
        XCTAssertEqual(try String(contentsOf: save, encoding: .utf8), "save")
    }

    func testItemsMoveBackInPlaceOfTheirLinks() throws {
        let fm = FileManager.default
        let data = group.appendingPathComponent("Data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("save".utf8).write(to: data.appendingPathComponent("save.rxdata"))
        try fm.createSymbolicLink(
            at: documents.appendingPathComponent("Data"), withDestinationURL: data)
        try fm.createSymbolicLink(
            at: documents.appendingPathComponent("Gone"),
            withDestinationURL: group.appendingPathComponent("Gone"))

        DataDirectory.moveItems(backFrom: group, to: documents)

        let moved = documents.appendingPathComponent("Data")
        let type = try fm.attributesOfItem(atPath: moved.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeDirectory)
        XCTAssertEqual(
            try String(contentsOf: moved.appendingPathComponent("save.rxdata"), encoding: .utf8), "save")
        XCTAssertFalse(fm.fileExists(atPath: group.appendingPathComponent("Data").path))
        XCTAssertNil(try? fm.attributesOfItem(atPath: documents.appendingPathComponent("Gone").path))
    }
}
