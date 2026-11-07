// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Json5

/// JSON5 reader for the developer-authored configs we load
/// (`mkxp.json`, `manifest.json`, `gamepad.json`, curated
/// `patches.json`). The engine parses these files with json5pp's
/// `parse5`. The launcher must accept the same input language. If it
/// does not, a config that the engine honors gets silently dropped
/// on the Swift side.
///
/// `normalizeToStrictJSON`, `parseObject`, and `decode` delegate to
/// the `Json5` package. That package vendors the engine's own
/// json5pp parser behind a C shim, so both sides run one grammar
/// implementation. See the `Json5` doc comment for the number
/// fidelity rules and for the strict-JSON stand-ins that replace
/// `infinity` and `NaN`.
public enum JSON5LiteParser {

    /// Rewrites the JSON5 surface that json5pp `parse5` accepts
    /// into strict JSON that `JSONSerialization` / `JSONDecoder`
    /// will take. On a JSON5 syntax error, the function returns the
    /// input unchanged. The strict parser then rejects it, the same
    /// way json5pp does. Callers that want the error position use
    /// `Json5.normalizeToStrictJSON` directly.
    public static func normalizeToStrictJSON(_ raw: String) -> String {
        (try? Json5.normalizeToStrictJSON(raw)) ?? raw
    }

    /// Normalize, then `JSONSerialization.jsonObject`. Returns nil
    /// if the normalized text is not a JSON object.
    public static func parseObject(_ raw: String) -> [String: Any]? {
        let cleaned = normalizeToStrictJSON(raw)
        guard let data = cleaned.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Normalize, then `JSONDecoder.decode`. Returns nil on parse
    /// failure.
    public static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let cleaned = normalizeToStrictJSON(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
