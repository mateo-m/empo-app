// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import Foundation
import Json5

/// The engine parses game configs such as `mkxp.json` and `gamepad.json`
/// with json5pp `parse5`. The launcher must accept the same input, or
/// the Swift side drops a config that the engine uses. The `Json5`
/// package wraps the engine's own json5pp parser for this.
public enum JSON5LiteParser {

    /// On a syntax error, this returns the input unchanged, so the
    /// strict parser rejects it as json5pp does.
    public static func normalizeToStrictJSON(_ raw: String) -> String {
        (try? Json5.normalizeToStrictJSON(raw)) ?? raw
    }

    public static func parseObject(_ raw: String) -> [String: Any]? {
        let strict = normalizeToStrictJSON(raw)
        return (try? JSONSerialization.jsonObject(with: Data(strict.utf8))) as? [String: Any]
    }

    public static func parseObjectReportingSyntaxError(_ raw: String) throws -> [String: Any]? {
        let strict = try Json5.normalizeToStrictJSON(raw)
        return (try? JSONSerialization.jsonObject(with: Data(strict.utf8))) as? [String: Any]
    }

    public static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let cleaned = normalizeToStrictJSON(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
