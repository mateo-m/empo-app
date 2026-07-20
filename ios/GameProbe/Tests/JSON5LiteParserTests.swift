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

    func testParseObjectWithTrailingCommas() {
        let raw = """
            {
              "patches": ["a.zip", "b",],
              "n": 1,
            }
            """
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["patches"] as? [String], ["a.zip", "b"])
        XCTAssertEqual(obj?["n"] as? Int, 1)
    }

    func testParseObjectWithBlockComments() {
        let raw = """
            {
              /* multi
                 line */
              "enabled": true, /* inline */ "count": 2
            }
            """
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["enabled"] as? Bool, true)
        XCTAssertEqual(obj?["count"] as? Int, 2)
    }

    func testParseObjectWithSingleQuotedStrings() {
        let raw = #"{'name': 'it\'s "here"', "other": 'plain'}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["name"] as? String, #"it's "here""#)
        XCTAssertEqual(obj?["other"] as? String, "plain")
    }

    func testParseObjectWithUnquotedKeys() {
        let raw = """
            {
              enabled: true,
              screenMode : "full",
              nested: { $inner_2: null }
            }
            """
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["enabled"] as? Bool, true)
        XCTAssertEqual(obj?["screenMode"] as? String, "full")
        let nested = obj?["nested"] as? [String: Any]
        XCTAssertNotNil(nested)
        XCTAssertTrue(nested?["$inner_2"] is NSNull)
    }

    func testNormalizePreservesCommentLookalikesInStrings() {
        let raw = #"{"url": "https://example.com", "glob": "a/*b*/c"}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["url"] as? String, "https://example.com")
        XCTAssertEqual(obj?["glob"] as? String, "a/*b*/c")
    }

    /// A developer-shipped mkxp.json exercising every JSON5 feature
    /// json5pp accepts that stock JSONSerialization rejects. The
    /// `patches` array must survive so EngineConfigProjector's
    /// managed-config projection doesn't drop overlay mounts the
    /// engine itself would honor.
    func testDevMkxpJsonWithJSON5FeaturesKeepsPatches() {
        let raw = """
            {
              /* shipped by the game dev */
              rgssVersion: 1,
              'windowTitle': 'My Game',
              "patches": [
                "patch1.zip",
                "patch2", // second overlay
              ],
              "RTP": ["rtp",],
            }
            """
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["patches"] as? [String], ["patch1.zip", "patch2"])
        XCTAssertEqual(obj?["RTP"] as? [String], ["rtp"])
        XCTAssertEqual(obj?["rgssVersion"] as? Int, 1)
        XCTAssertEqual(obj?["windowTitle"] as? String, "My Game")
    }

    func testParseObjectStillNilOnGarbage() {
        XCTAssertNil(JSON5LiteParser.parseObject("not json at all {"))
        XCTAssertNil(JSON5LiteParser.parseObject("[1, 2]"))
    }
}
