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
            try skipOrFail("Shift-JIS encoding is unavailable on this platform")
        }
        // The fixture must not be valid UTF-8, or the test would
        // exercise the wrong branch.
        XCTAssertNil(String(data: sjis, encoding: .utf8))
        XCTAssertEqual(sjis.decodeAsLooseText(), title)
    }

    func testWindows1252AccentsDecodeCorrectly() throws {
        // "é" (0xE9) followed by "m" (0x6D) is also one valid
        // Shift-JIS kanji (駑). The Western decode must win here.
        let title = "Pokémon Empyrean"
        guard let cp1252 = title.data(using: .windowsCP1252) else {
            try skipOrFail("Windows-1252 encoding is unavailable on this platform")
        }
        XCTAssertNil(String(data: cp1252, encoding: .utf8))
        XCTAssertNotNil(String(data: cp1252, encoding: .shiftJIS))
        XCTAssertEqual(cp1252.decodeAsLooseText(), title)
    }

    func testWindows1252FullINIDecodesCorrectly() throws {
        let ini = "[Game]\r\nLibrary=RGSS104E.dll\r\nScripts=Data\\Scripts.rxdata\r\nTitle=Pokémon Empyrean\r\n"
        guard let cp1252 = ini.data(using: .windowsCP1252) else {
            try skipOrFail("Windows-1252 encoding is unavailable on this platform")
        }
        XCTAssertEqual(cp1252.decodeAsLooseText(), ini)
    }

    func testShiftJISFullINIStillDecodesAsShiftJIS() throws {
        // Kana in the title marks the file as Japanese even though
        // most of its bytes are ASCII.
        let ini = "[Game]\r\nLibrary=RGSS102J.dll\r\nTitle=ポケットモンスター\r\n"
        guard let sjis = ini.data(using: .shiftJIS) else {
            try skipOrFail("Shift-JIS encoding is unavailable on this platform")
        }
        XCTAssertEqual(sjis.decodeAsLooseText(), ini)
    }

    func testHalfWidthKanaRunDecodesAsShiftJIS() throws {
        let title = "ﾎﾟｹｯﾄ"
        guard let sjis = title.data(using: .shiftJIS) else {
            try skipOrFail("Shift-JIS encoding is unavailable on this platform")
        }
        XCTAssertNil(String(data: sjis, encoding: .utf8))
        XCTAssertEqual(sjis.decodeAsLooseText(), title)
    }

    func testArbitraryHighBytesNeverDecodeToNil() {
        // 0xFF is invalid as UTF-8 here and invalid as a Shift-JIS
        // lead byte. The Latin-1 fallback maps every byte.
        let junk = Data([0xFF, 0x00, 0x81, 0xAD, 0xFE])
        XCTAssertNotNil(junk.decodeAsLooseText())

        let everyByte = Data((0...255).map { UInt8($0) })
        XCTAssertNotNil(everyByte.decodeAsLooseText())
    }
}
