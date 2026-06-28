import XCTest

@testable import GameProbe

final class JSON5LiteParserTests: XCTestCase {

    func testStripLineCommentsPreservesStringURLs() {
        let raw = """
            {
              "url": "https://example.com", // not a comment
              "n": 1 // trailing
            }
            """
        let cleaned = JSON5LiteParser.stripLineComments(raw)
        XCTAssertTrue(cleaned.contains("https://example.com"))
        XCTAssertFalse(cleaned.contains("// not"))
        XCTAssertFalse(cleaned.contains("// trailing"))
    }

    func testParseObjectWithLineComments() {
        let raw = """
            {
              // header
              "enabled": true,
              "count": 2
            }
            """
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["enabled"] as? Bool, true)
        XCTAssertEqual(obj?["count"] as? Int, 2)
    }

    func testStripLineCommentsInsideQuotedSlash() {
        let raw = #""path": "foo//bar""#
        let cleaned = JSON5LiteParser.stripLineComments(raw)
        XCTAssertEqual(cleaned, raw)
    }
}
