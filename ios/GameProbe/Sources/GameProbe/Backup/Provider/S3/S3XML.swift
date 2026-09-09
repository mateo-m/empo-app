import Foundation

/// The little that Empo has to read out of an S3 answer.
///
/// S3 answers XML. The four shapes Empo reads are fixed and shallow:
/// an error, a page of objects, the id of a multipart upload, and a
/// list of parts. `XMLParser` sits in a second module on Linux, which
/// this package does not carry, and the whole need is "give me the
/// text inside this element". So it reads the text.
///
/// This is not an XML parser. It takes no attribute, no namespace
/// prefix, and no comment. Do not point it at a document Empo does
/// not control the shape of.
enum S3XML {

    /// The text inside every `<name>...</name>` of `xml`, in order.
    static func blocks(named name: String, in xml: String) -> [String] {
        let open = "<\(name)>"
        let close = "</\(name)>"
        var found: [String] = []
        var cursor = xml.startIndex
        while let start = xml.range(of: open, range: cursor..<xml.endIndex),
            let end = xml.range(of: close, range: start.upperBound..<xml.endIndex)
        {
            found.append(String(xml[start.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }
        return found
    }

    /// The text inside the first `<name>`, or `nil` where the answer
    /// carries none.
    static func value(of name: String, in xml: String) -> String? {
        guard let first = blocks(named: name, in: xml).first else { return nil }
        return unescape(first)
    }

    static func int64(_ name: String, in xml: String) -> Int64? {
        guard let text = value(of: name, in: xml) else { return nil }
        return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func flag(_ name: String, in xml: String) -> Bool {
        value(of: name, in: xml)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The five named entities and the numeric ones. MinIO and the
    /// other Go services write a quote as `&#34;`, so the ETag of a
    /// ListParts answer reads wrong without the numeric form, and
    /// the commit that quotes it back gets InvalidPart.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";") else { break }
            let name = rest[rest.index(after: amp)..<semi]
            if let decoded = character(ofEntity: name) {
                out.append(decoded)
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest.dropFirst()
            }
        }
        out += rest
        return out
    }

    private static func character(ofEntity name: Substring) -> Character? {
        switch name {
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "amp": return "&"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let code =
            digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        guard let code, let scalar = Unicode.Scalar(code) else { return nil }
        return Character(scalar)
    }

    /// The same five, the other way, for the body Empo writes.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
