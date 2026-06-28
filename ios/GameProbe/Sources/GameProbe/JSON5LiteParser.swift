import Foundation

/// Tiny JSON5-ish reader used for the developer-authored configs we
/// load (`mkxp.json`, `manifest.json`, `gamepad.json`, curated
/// `patches.json`). Handles `//` line comments. Doesn't handle block
/// comments, trailing commas, or single-quoted strings.
///
/// `JSONSerialization` and `JSONDecoder` reject `//` outright, so any
/// loader that wants to consume those config files has to pre-clean
/// the bytes. The state machine in `stripLineComments` walks the raw
/// text once and drops `//`-to-EOL runs, leaving anything inside a
/// string literal intact (a naive `range(of: "//")` per line trips
/// over URLs in string values).
public enum JSON5LiteParser {

    /// Strip `//` line comments. CRLF / CR get normalized to LF first
    /// so the comment-skip loop doesn't run away if the file came
    /// from a Windows editor.
    public static func stripLineComments(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var out = ""
        out.reserveCapacity(normalized.count)
        var inString = false
        var escaped = false
        var i = normalized.startIndex

        while i < normalized.endIndex {
            let c = normalized[i]

            if escaped {
                out.append(c)
                escaped = false
                i = normalized.index(after: i)
                continue
            }

            if c == "\\" && inString {
                out.append(c)
                escaped = true
                i = normalized.index(after: i)
                continue
            }

            if c == "\"" {
                inString.toggle()
                out.append(c)
                i = normalized.index(after: i)
                continue
            }

            if !inString && c == "/" {
                let next = normalized.index(after: i)
                if next < normalized.endIndex && normalized[next] == "/" {
                    while i < normalized.endIndex && normalized[i] != "\n" {
                        i = normalized.index(after: i)
                    }
                    continue
                }
            }

            out.append(c)
            i = normalized.index(after: i)
        }

        return out
    }

    /// Strip-then-`JSONSerialization.jsonObject`. Returns nil if the
    /// cleaned text isn't a JSON object.
    public static func parseObject(_ raw: String) -> [String: Any]? {
        let cleaned = stripLineComments(raw)
        guard let data = cleaned.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Strip-then-`JSONDecoder.decode`. Returns nil on parse failure.
    public static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let cleaned = stripLineComments(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Convenience for callers holding `Data` instead of `String`.
    /// Decodes the data as UTF-8 first.
    public static func stripLineComments(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return stripLineComments(text).data(using: .utf8)
    }
}
