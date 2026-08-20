import Foundation
import XCTest

@testable import Json5

final class Json5Tests: XCTestCase {

    // MARK: - Helpers

    private func parseObject(_ raw: String) throws -> [String: Any] {
        let strict = try Json5.normalizeToStrictJSON(raw)
        let data = try XCTUnwrap(strict.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Input that the parser must reject.
    ///
    /// A thrown error fails the calling check. XCTSkip must not stand
    /// in here: a skip reports the check as not run, so a parser that
    /// stopped rejecting bad input would look clean.
    private struct ParserAcceptedBadInput: Error {
        let raw: String
    }

    private func syntaxError(_ raw: String) throws -> Json5SyntaxError {
        do {
            _ = try Json5.normalizeToStrictJSON(raw)
        } catch let error as Json5SyntaxError {
            return error
        }
        throw ParserAcceptedBadInput(raw: raw)
    }

    // MARK: - JSON5 feature acceptance

    func testBlockAndLineComments() throws {
        let raw = """
            {
              /* multi
                 line */
              "enabled": true, // trailing
              "count": 2 /* inline */
            }
            """
        let obj = try parseObject(raw)
        XCTAssertEqual(obj["enabled"] as? Bool, true)
        XCTAssertEqual(obj["count"] as? Int, 2)
    }

    func testTrailingCommas() throws {
        let raw = #"{ "list": ["a", "b",], "n": 1, }"#
        let obj = try parseObject(raw)
        XCTAssertEqual(obj["list"] as? [String], ["a", "b"])
        XCTAssertEqual(obj["n"] as? Int, 1)
    }

    func testSingleQuotedStrings() throws {
        let raw = #"{'name': 'it\'s "here"', "other": 'plain'}"#
        let obj = try parseObject(raw)
        XCTAssertEqual(obj["name"] as? String, #"it's "here""#)
        XCTAssertEqual(obj["other"] as? String, "plain")
    }

    func testUnquotedKeys() throws {
        let raw = "{ enabled: true, $inner_2: null }"
        let obj = try parseObject(raw)
        XCTAssertEqual(obj["enabled"] as? Bool, true)
        XCTAssertTrue(obj["$inner_2"] is NSNull)
    }

    /// json5pp requires the colon directly after an unquoted key.
    /// A space or a comment before the colon makes the engine
    /// throw. A quoted key keeps allowing whitespace before the
    /// colon.
    func testUnquotedKeyRequiresImmediateColon() throws {
        XCTAssertThrowsError(
            try Json5.normalizeToStrictJSON(#"{ screenMode : "full" }"#))
        XCTAssertThrowsError(
            try Json5.normalizeToStrictJSON("{ screenMode /*c*/: \"full\" }"))
        let quoted = try parseObject(#"{ "screenMode" : "full" }"#)
        XCTAssertEqual(quoted["screenMode"] as? String, "full")
    }

    func testHexNumbers() throws {
        let raw = "{ a: 0x1A, b: -0x10, c: +0xFF, d: 0Xbeef }"
        let obj = try parseObject(raw)
        XCTAssertEqual((obj["a"] as? NSNumber)?.intValue, 26)
        XCTAssertEqual((obj["b"] as? NSNumber)?.intValue, -16)
        XCTAssertEqual((obj["c"] as? NSNumber)?.intValue, 255)
        XCTAssertEqual((obj["d"] as? NSNumber)?.intValue, 48879)
    }

    /// json5pp yields IEEE infinity for `infinity` and NaN for
    /// `NaN`. Strict JSON has no literal for either value. The
    /// bridge stands in the greatest finite double for infinity and
    /// null for NaN.
    func testInfinityAndNaNStandIns() throws {
        let raw = "{ pos: infinity, neg: -infinity, nan: NaN }"
        let obj = try parseObject(raw)
        XCTAssertEqual(
            (obj["pos"] as? NSNumber)?.doubleValue,
            Double.greatestFiniteMagnitude
        )
        XCTAssertEqual(
            (obj["neg"] as? NSNumber)?.doubleValue,
            -Double.greatestFiniteMagnitude
        )
        XCTAssertTrue(obj["nan"] is NSNull)
    }

    /// json5pp matches `infinity` in lower case only. It rejects
    /// the JSON5 spec spelling `Infinity`.
    func testRejectsCapitalInfinity() throws {
        XCTAssertThrowsError(
            try Json5.normalizeToStrictJSON(#"{"a": Infinity}"#))
    }

    func testDecimalPointEdges() throws {
        let raw = #"{"a": .5, "b": 5., "c": -.25, "d": 5.e2, "e": .5e1}"#
        let obj = try parseObject(raw)
        XCTAssertEqual((obj["a"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((obj["b"] as? NSNumber)?.doubleValue, 5.0)
        XCTAssertEqual((obj["c"] as? NSNumber)?.doubleValue, -0.25)
        XCTAssertEqual((obj["d"] as? NSNumber)?.doubleValue, 500.0)
        XCTAssertEqual((obj["e"] as? NSNumber)?.doubleValue, 5.0)
    }

    func testLineContinuationsInStrings() throws {
        let lf = "{ \"a\": \"line \\\njoined\", 'b': 'also \\\njoined' }"
        var obj = try parseObject(lf)
        XCTAssertEqual(obj["a"] as? String, "line joined")
        XCTAssertEqual(obj["b"] as? String, "also joined")

        let crlf = "{ \"a\": \"line \\\r\njoined\" }"
        obj = try parseObject(crlf)
        XCTAssertEqual(obj["a"] as? String, "line joined")
    }

    func testCommentMarkersInsideStringsStay() throws {
        let raw = #"{"url": "https://example.com", "glob": "a/*b*/c"}"#
        let obj = try parseObject(raw)
        XCTAssertEqual(obj["url"] as? String, "https://example.com")
        XCTAssertEqual(obj["glob"] as? String, "a/*b*/c")
    }

    // MARK: - Inputs json5pp rejects

    func testRejectsMalformedInput() throws {
        XCTAssertThrowsError(
            try Json5.normalizeToStrictJSON(#"{"a": 1} /* trailing"#))
        XCTAssertThrowsError(try Json5.normalizeToStrictJSON(#"{"a": [,]}"#))
        XCTAssertThrowsError(try Json5.normalizeToStrictJSON(#"{"a": 0x}"#))
        XCTAssertThrowsError(try Json5.normalizeToStrictJSON(#"{"a": 1e}"#))
        XCTAssertThrowsError(try Json5.normalizeToStrictJSON(#"{"a": 007}"#))
    }

    // MARK: - Error positions

    func testErrorPositionOnLineThree() throws {
        let raw = """
            {
              "a": 1,
              "b": @
            }
            """
        let error = try syntaxError(raw)
        XCTAssertEqual(error.line, 3)
        XCTAssertEqual(error.column, 8)
        XCTAssertTrue(
            error.message.contains("illegal character"),
            "unexpected message: \(error.message)"
        )
    }

    func testErrorPositionAtUnexpectedEnd() throws {
        let error = try syntaxError(#"{"a": 1"#)
        XCTAssertEqual(error.line, 1)
        XCTAssertEqual(error.column, 8)
        XCTAssertTrue(
            error.message.contains("unexpected EOS"),
            "unexpected message: \(error.message)"
        )
    }

    func testErrorPositionAfterWindowsNewlines() throws {
        let raw = "{\r\n  \"a\": 1,\r\n  \"b\": !\r\n}"
        let error = try syntaxError(raw)
        XCTAssertEqual(error.line, 3)
        XCTAssertEqual(error.column, 8)
    }

    // MARK: - Number fidelity

    private struct Versioned: Decodable {
        let version: Int
    }

    /// An integer must stay an integer token so `JSONDecoder` can
    /// decode it as a Swift `Int`.
    func testIntegerStaysDecodableAsInt() throws {
        let strict = try Json5.normalizeToStrictJSON(#"{"version": 1}"#)
        let data = try XCTUnwrap(strict.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Versioned.self, from: data)
        XCTAssertEqual(decoded.version, 1)
    }

    func testDoublePrecisionSurvives() throws {
        let obj = try parseObject(
            #"{"a": 0.1, "b": 1.2345678901234567, "c": 1e300}"#)
        XCTAssertEqual((obj["a"] as? NSNumber)?.doubleValue, 0.1)
        XCTAssertEqual(
            (obj["b"] as? NSNumber)?.doubleValue, 1.2345678901234567)
        XCTAssertEqual((obj["c"] as? NSNumber)?.doubleValue, 1e300)
    }

    /// json5pp stores a plain decimal integer as a C `int` when it
    /// fits. Both 32-bit extremes must survive exactly.
    func testInt32BoundariesSurviveExactly() throws {
        let obj = try parseObject(
            #"{"max": 2147483647, "min": -2147483648}"#)
        XCTAssertEqual((obj["max"] as? NSNumber)?.int64Value, 2_147_483_647)
        XCTAssertEqual((obj["min"] as? NSNumber)?.int64Value, -2_147_483_648)
    }

    /// Beyond the 32-bit range, json5pp falls back to a double.
    /// Integral doubles up to 2^53 stay exact.
    func testIntegersBeyondInt32StayExactUpToTwoPow53() throws {
        let obj = try parseObject(
            #"{"a": 2147483648, "b": 9007199254740992}"#)
        XCTAssertEqual((obj["a"] as? NSNumber)?.int64Value, 2_147_483_648)
        XCTAssertEqual(
            (obj["b"] as? NSNumber)?.int64Value, 9_007_199_254_740_992)
    }

    /// Above 2^53 the double format cannot carry every integer.
    /// This pins the documented limit. The engine has the same
    /// limit, so the host must not be more precise than the engine.
    func testIntegersAboveTwoPow53LoseToDoubleFormat() throws {
        let obj = try parseObject(#"{"a": 9007199254740993}"#)
        XCTAssertEqual(
            (obj["a"] as? NSNumber)?.doubleValue, 9_007_199_254_740_992.0)
    }

    // MARK: - Vendored copy identity

    /// The vendored json5pp.hpp must stay byte-identical to the
    /// engine's copy. When the engine updates the parser, re-copy
    /// the header into Sources/json5cpp/.
    func testVendoredHeaderMatchesEngineCopy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vendored = packageRoot
            .appendingPathComponent("Sources/json5cpp/json5pp.hpp")
        let engine = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mkxp-z-apple-mobile/src/util/json5pp.hpp")
        guard FileManager.default.fileExists(atPath: engine.path) else {
            try skipOrFail(
                "Engine submodule is not checked out at \(engine.path)")
        }
        let vendoredBytes = try Data(contentsOf: vendored)
        let engineBytes = try Data(contentsOf: engine)
        XCTAssertEqual(
            vendoredBytes, engineBytes,
            "Vendored json5pp.hpp differs from the engine copy"
        )
    }
}
