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
              screenMode: "full",
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

    /// json5pp requires the colon directly after an unquoted key.
    /// A space or a comment before the colon makes the engine throw.
    /// The host must reject the same files. A quoted key keeps
    /// allowing whitespace before the colon.
    func testUnquotedKeyRequiresImmediateColon() {
        XCTAssertNil(JSON5LiteParser.parseObject(#"{ screenMode : "full" }"#))
        XCTAssertNil(JSON5LiteParser.parseObject("{ screenMode /*c*/: \"full\" }"))
        let quoted = JSON5LiteParser.parseObject(#"{ "screenMode" : "full" }"#)
        XCTAssertEqual(quoted?["screenMode"] as? String, "full")
    }

    func testNormalizePreservesCommentLookalikesInStrings() {
        let raw = #"{"url": "https://example.com", "glob": "a/*b*/c"}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["url"] as? String, "https://example.com")
        XCTAssertEqual(obj?["glob"] as? String, "a/*b*/c")
    }

    /// A developer-shipped mkxp.json that uses every JSON5 feature
    /// that json5pp accepts and stock JSONSerialization rejects. The
    /// `patches` array must survive. The managed-config projection in
    /// EngineConfigProjector must not drop overlay mounts that the
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

    // MARK: - Full JSON5 surface (mirrors json5pp parse5)

    func testParseObjectWithHexNumbers() {
        let raw = "{ a: 0x1A, b: -0x10, c: +0xFF, d: 0Xbeef }"
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual((obj?["a"] as? NSNumber)?.intValue, 26)
        XCTAssertEqual((obj?["b"] as? NSNumber)?.intValue, -16)
        XCTAssertEqual((obj?["c"] as? NSNumber)?.intValue, 255)
        XCTAssertEqual((obj?["d"] as? NSNumber)?.intValue, 48879)
    }

    func testParseObjectWithDecimalPointEdges() {
        let raw = #"{"a": .5, "b": 5., "c": -.25, "d": 5.e2, "e": .5e1}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual((obj?["a"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((obj?["b"] as? NSNumber)?.doubleValue, 5.0)
        XCTAssertEqual((obj?["c"] as? NSNumber)?.doubleValue, -0.25)
        XCTAssertEqual((obj?["d"] as? NSNumber)?.doubleValue, 500.0)
        XCTAssertEqual((obj?["e"] as? NSNumber)?.doubleValue, 5.0)
    }

    func testParseObjectWithExplicitPlusSign() {
        let raw = #"{"a": +42, "b": +1.5e2, "c": 1e+3, "d": +.5}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual((obj?["a"] as? NSNumber)?.intValue, 42)
        XCTAssertEqual((obj?["b"] as? NSNumber)?.doubleValue, 150.0)
        XCTAssertEqual((obj?["c"] as? NSNumber)?.doubleValue, 1000.0)
        XCTAssertEqual((obj?["d"] as? NSNumber)?.doubleValue, 0.5)
    }

    /// json5pp accepts lower-case `infinity` and `NaN`. Strict JSON
    /// cannot carry either value. The rewrite stands in the greatest
    /// finite double for infinity and null for NaN. json5pp rejects
    /// the spec spelling `Infinity`, so this parser does too.
    func testParseObjectWithInfinityAndNaN() {
        let raw = "{ pos: infinity, neg: -infinity, nan: NaN }"
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(
            (obj?["pos"] as? NSNumber)?.doubleValue,
            Double.greatestFiniteMagnitude
        )
        XCTAssertEqual(
            (obj?["neg"] as? NSNumber)?.doubleValue,
            -Double.greatestFiniteMagnitude
        )
        XCTAssertTrue(obj?["nan"] is NSNull)
    }

    func testInfinityAndNaNStayUsableAsKeys() {
        let raw = "{ infinity: 1, NaN: 2 }"
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual((obj?["infinity"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((obj?["NaN"] as? NSNumber)?.intValue, 2)
    }

    func testParseObjectWithStringEscapes() {
        let raw = #"{"u": "ABC", "t": "tab\there", "s": "sla\/sh", "q": "quo\'te"}"#
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["u"] as? String, "ABC")
        XCTAssertEqual(obj?["t"] as? String, "tab\there")
        XCTAssertEqual(obj?["s"] as? String, "sla/sh")
        XCTAssertEqual(obj?["q"] as? String, "quo'te")

        let unicode = "{\"w\": \"A\\u0042C\"}"
        let uobj = JSON5LiteParser.parseObject(unicode)
        XCTAssertEqual(uobj?["w"] as? String, "ABC")
    }

    func testParseObjectWithLineContinuationInStrings() {
        let lf = "{ \"a\": \"line \\\njoined\", 'b': 'also \\\njoined' }"
        var obj = JSON5LiteParser.parseObject(lf)
        XCTAssertEqual(obj?["a"] as? String, "line joined")
        XCTAssertEqual(obj?["b"] as? String, "also joined")

        let crlf = "{ \"a\": \"line \\\r\njoined\" }"
        obj = JSON5LiteParser.parseObject(crlf)
        XCTAssertEqual(obj?["a"] as? String, "line joined")
    }

    func testCommentMarkersInsideSingleQuotedStringsStay() {
        let raw = "{ 'url': 'https://example.com', 'glob': 'a/*b*/c' }"
        let obj = JSON5LiteParser.parseObject(raw)
        XCTAssertEqual(obj?["url"] as? String, "https://example.com")
        XCTAssertEqual(obj?["glob"] as? String, "a/*b*/c")
    }

    // MARK: - Inputs json5pp also rejects

    func testRejectsUnterminatedBlockComment() {
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": 1} /* trailing"#))
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": /* 1}"#))
    }

    func testRejectsCommaWithoutValue() {
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": [,]}"#))
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": [1,,]}"#))
        XCTAssertNil(JSON5LiteParser.parseObject("{,}"))
    }

    func testRejectsCapitalInfinity() {
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": Infinity}"#))
    }

    func testRejectsMalformedNumbers() {
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": 0x}"#))
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": 1e}"#))
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": -}"#))
        XCTAssertNil(JSON5LiteParser.parseObject(#"{"a": 007}"#))
    }
}
