import Foundation
import XCTest

@testable import GameProbe

final class DataLooseTextTests: XCTestCase {

    func testValidUTF8PassesThrough() {
        let text = "Pokémon Uranium 🎮"
        XCTAssertEqual(Data(text.utf8).decodeAsLooseText(), text)
    }

    func testShiftJISBytesDecodeCorrectly() throws {
        let title = "ポケットモンスター"
        guard let sjis = title.data(using: .shiftJIS) else {
            throw XCTSkip("Shift-JIS encoding is unavailable on this platform")
        }
        // The fixture must not be valid UTF-8, or the test would
        // exercise the wrong branch.
        XCTAssertNil(String(data: sjis, encoding: .utf8))
        XCTAssertEqual(sjis.decodeAsLooseText(), title)
    }

    func testArbitraryHighBytesNeverDecodeToNil() {
        // 0xFF is invalid as UTF-8 here and invalid as a Shift-JIS
        // lead byte; the Latin-1 fallback maps every byte.
        let junk = Data([0xFF, 0x00, 0x81, 0xAD, 0xFE])
        XCTAssertNotNil(junk.decodeAsLooseText())

        let everyByte = Data((0...255).map { UInt8($0) })
        XCTAssertNotNil(everyByte.decodeAsLooseText())
    }
}
