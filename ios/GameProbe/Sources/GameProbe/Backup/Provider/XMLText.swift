import Foundation

enum XMLText {

    /// The five named entities and the numeric ones. MinIO and the other Go services write a quote
    /// as `&#34;`, so an S3 ETag reads wrong without the numeric form, and the commit that quotes it
    /// back gets InvalidPart.
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

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
