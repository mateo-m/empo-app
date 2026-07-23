import Foundation
import json5cpp

/// A JSON5 syntax error from the engine's json5pp parser.
///
/// `line` and `column` are 1-based. They point at the input byte
/// that made the parser throw. When the input ends too early, they
/// point one column past the last byte.
public struct Json5SyntaxError: Error, Equatable, Sendable {
    public let message: String
    public let line: Int
    public let column: Int

    public init(message: String, line: Int, column: Int) {
        self.message = message
        self.line = line
        self.column = column
    }
}

/// Swift front end for the engine's JSON5 parser (json5pp).
///
/// The engine parses `mkxp.json` and `patches.json` with json5pp's
/// `parse5`. This wrapper runs the same parser over the same bytes,
/// so the launcher accepts exactly the input language the engine
/// accepts.
///
/// Number fidelity notes:
/// - json5pp stores a plain decimal integer as a C `int` when it
///   fits. The output keeps it as an integer token, so `1` stays
///   decodable as a Swift `Int`.
/// - Every other number becomes a C `double`. This includes hex
///   numbers and decimal integers beyond the 32-bit range. Integral
///   doubles up to 2^53 stay exact. Larger integers lose precision
///   to the double format, the same way they do inside the engine.
/// - Finite doubles serialize with round-trip precision, so values
///   such as `0.1` survive exactly.
/// - json5pp yields IEEE infinity for `infinity` and NaN for `NaN`.
///   Strict JSON has no literal for either value. The output stands
///   in the greatest finite double for infinity and `null` for NaN.
public enum Json5 {

    /// Parse JSON5 text with json5pp `parse5` and return strict
    /// JSON for `JSONSerialization` or `JSONDecoder`.
    ///
    /// - Throws: `Json5SyntaxError` when json5pp rejects the input.
    public static func normalizeToStrictJSON(_ input: String) throws -> String {
        let result = input.utf8CString.withUnsafeBufferPointer { buffer in
            json5_bridge_normalize(buffer.baseAddress, buffer.count - 1)
        }
        if let json = result.json {
            defer { json5_bridge_free(json) }
            return String(cString: json)
        }
        let message: String
        if let errorMessage = result.error_message {
            message = String(cString: errorMessage)
            json5_bridge_free(errorMessage)
        } else {
            message = "unknown JSON5 error"
        }
        throw Json5SyntaxError(
            message: message,
            line: Int(result.error_line),
            column: Int(result.error_column)
        )
    }
}
