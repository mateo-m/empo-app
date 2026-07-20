import Foundation

/// Tiny JSON5-ish reader used for the developer-authored configs we
/// load (`mkxp.json`, `manifest.json`, `gamepad.json`, curated
/// `patches.json`). The engine parses these files with json5pp's
/// `parse5`, so the launcher has to accept the same surface or a
/// config the engine would honor gets silently dropped on the Swift
/// side. `normalizeToStrictJSON` covers the JSON5 features that
/// actually appear in shipped configs: `//` and `/* */` comments,
/// trailing commas, single-quoted strings, and unquoted identifier
/// keys. Not covered: hex numbers, `Infinity`/`NaN`, bare leading
/// `+` or decimal points, and `\x` escapes.
///
/// `JSONSerialization` and `JSONDecoder` reject all of the above
/// outright, so any loader that wants to consume those config files
/// has to pre-clean the bytes. The scanners below walk the raw text
/// and leave anything inside a string literal intact (a naive
/// `range(of: "//")` per line trips over URLs in string values).
public enum JSON5LiteParser {

    /// Strip `//` line comments only. Kept for callers that want a
    /// minimal clean without the full JSON5 normalization. CRLF / CR
    /// get normalized to LF first so the comment-skip loop doesn't
    /// run away if the file came from a Windows editor.
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

    /// Rewrite the JSON5 surface json5pp `parse5` accepts into strict
    /// JSON that `JSONSerialization` / `JSONDecoder` will take.
    public static func normalizeToStrictJSON(_ raw: String) -> String {
        rewriteTokens(convertStringsAndStripComments(raw))
    }

    /// Strip-then-`JSONSerialization.jsonObject`. Returns nil if the
    /// normalized text isn't a JSON object.
    public static func parseObject(_ raw: String) -> [String: Any]? {
        let cleaned = normalizeToStrictJSON(raw)
        guard let data = cleaned.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    /// Strip-then-`JSONDecoder.decode`. Returns nil on parse failure.
    public static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let cleaned = normalizeToStrictJSON(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Convenience for callers holding `Data` instead of `String`.
    /// Decodes the data as UTF-8 first.
    public static func stripLineComments(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return stripLineComments(text).data(using: .utf8)
    }

    /// Pass 1: drop `//` and `/* */` comments and re-emit every
    /// string literal double-quoted, so pass 2 only has to reason
    /// about double quotes. Inside a single-quoted string, embedded
    /// `"` gets escaped and `\'` loses its now-unnecessary escape.
    /// JSON5 line continuations (`\` + newline) are dropped.
    private static func convertStringsAndStripComments(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chars = Array(normalized)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\"" || c == "'" {
                let quote = c
                out.append("\"")
                i += 1
                while i < chars.count {
                    let s = chars[i]
                    if s == "\\" {
                        guard i + 1 < chars.count else {
                            i += 1
                            break
                        }
                        let esc = chars[i + 1]
                        if esc == "\n" {
                            // line continuation
                        } else if esc == "'" {
                            out.append("'")
                        } else {
                            out.append("\\")
                            out.append(esc)
                        }
                        i += 2
                        continue
                    }
                    if s == quote {
                        i += 1
                        break
                    }
                    if s == "\"" {
                        out.append("\\\"")
                        i += 1
                        continue
                    }
                    out.append(s)
                    i += 1
                }
                out.append("\"")
                continue
            }

            if c == "/" && i + 1 < chars.count {
                if chars[i + 1] == "/" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                    continue
                }
                if chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") {
                        i += 1
                    }
                    i = min(i + 2, chars.count)
                    // A space keeps tokens on either side apart.
                    out.append(" ")
                    continue
                }
            }

            out.append(c)
            i += 1
        }

        return out
    }

    /// Pass 2 (comments already gone, all strings double-quoted):
    /// drop trailing commas before `}` / `]` and wrap unquoted
    /// identifier keys — a bare identifier whose next non-whitespace
    /// character is `:` — in double quotes. Bare identifiers in value
    /// position (`true`, `false`, `null`) pass through untouched.
    private static func rewriteTokens(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                out.append(c)
                i += 1
                while i < chars.count {
                    let s = chars[i]
                    out.append(s)
                    i += 1
                    if s == "\\" {
                        if i < chars.count {
                            out.append(chars[i])
                            i += 1
                        }
                        continue
                    }
                    if s == "\"" { break }
                }
                continue
            }

            if c == "," {
                var j = i + 1
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if j >= chars.count || chars[j] == "}" || chars[j] == "]" {
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
                continue
            }

            if isIdentifierStart(c) {
                var j = i
                while j < chars.count && isIdentifierPart(chars[j]) { j += 1 }
                let ident = String(chars[i..<j])
                var k = j
                while k < chars.count && chars[k].isWhitespace { k += 1 }
                if k < chars.count && chars[k] == ":" {
                    out.append("\"")
                    out.append(ident)
                    out.append("\"")
                } else {
                    out.append(ident)
                }
                i = j
                continue
            }

            out.append(c)
            i += 1
        }

        return out
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "$"
    }

    private static func isIdentifierPart(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }
}
