import Foundation

/// The little that Empo has to read out of a WebDAV answer.
///
/// WebDAV answers XML, and every element sits in the `DAV:`
/// namespace. Each server picks its own prefix for it. Nextcloud
/// writes `<d:response>`, Apache `mod_dav` writes `<D:response>` and
/// then names the properties with a second prefix of its own, such as
/// `<lp1:getcontentlength>`. A reader that matched a prefix would
/// read one server and not the other.
///
/// So this reader matches the local name and drops the prefix. It
/// counts nesting, and it takes a self-closing tag, because
/// `<d:collection/>` is how a server says "this is a collection".
///
/// `XMLParser` sits in a second module on Linux, which this package
/// does not carry, and the whole need is "give me the text inside
/// this element". So it reads the text.
///
/// This is not an XML parser. It takes no attribute, no CDATA
/// section, and no numeric entity. Do not point it at a document
/// Empo does not control the shape of.
enum DAVXML {

    /// One tag of the document.
    private struct Tag {
        let localName: String
        let isClose: Bool
        let isSelfClosing: Bool
        /// Where the text after this tag starts.
        let contentStart: String.Index
        /// Where the tag itself starts.
        let start: String.Index
    }

    /// The text inside every `<name>...</name>` of `xml`, in order,
    /// whatever prefix the server put on the name.
    ///
    /// A block that holds a second element of the same name keeps it,
    /// because the count of open tags decides where the block ends.
    static func blocks(_ name: String, in xml: String) -> [String] {
        let wanted = name.lowercased()
        var found: [String] = []
        var depth = 0
        var openedAt: String.Index?

        for tag in tags(in: xml) where tag.localName == wanted {
            if tag.isSelfClosing {
                if depth == 0 { found.append("") }
                continue
            }
            if tag.isClose {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start = openedAt {
                    found.append(String(xml[start..<tag.start]))
                    openedAt = nil
                }
                continue
            }
            if depth == 0 { openedAt = tag.contentStart }
            depth += 1
        }
        return found
    }

    /// The text inside the first `<name>`, or `nil` where the answer
    /// carries none.
    static func value(_ name: String, in xml: String) -> String? {
        guard let first = blocks(name, in: xml).first else { return nil }
        return unescape(first).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func int64(_ name: String, in xml: String) -> Int64? {
        guard let text = value(name, in: xml), !text.isEmpty else { return nil }
        return Int64(text)
    }

    /// Whether the document holds an element of this name at all.
    /// `<d:collection/>` carries no text, so a value read cannot
    /// answer it.
    static func has(_ name: String, in xml: String) -> Bool {
        let wanted = name.lowercased()
        return tags(in: xml).contains { $0.localName == wanted && !$0.isClose }
    }

    // MARK: - The scanner

    /// Every tag of the document, in order. It steps over the XML
    /// declaration, a comment, and a CDATA section.
    private static func tags(in xml: String) -> [Tag] {
        var found: [Tag] = []
        var cursor = xml.startIndex

        while let open = xml[cursor...].firstIndex(of: "<") {
            let after = xml.index(after: open)
            guard after < xml.endIndex else { break }

            if let skipped = skip(from: open, in: xml) {
                cursor = skipped
                continue
            }
            guard let close = xml[after...].firstIndex(of: ">") else { break }

            let inside = xml[after..<close]
            let isClose = inside.hasPrefix("/")
            let isSelfClosing = inside.hasSuffix("/")
            let body = inside.drop(while: { $0 == "/" })
            let name = body.prefix { !$0.isWhitespace && $0 != "/" }
            let local = name.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
            let contentStart = xml.index(after: close)

            if !local.isEmpty {
                found.append(
                    Tag(
                        localName: local,
                        isClose: isClose,
                        isSelfClosing: isSelfClosing && !isClose,
                        contentStart: contentStart,
                        start: open))
            }
            cursor = contentStart
        }
        return found
    }

    /// Where to carry on when the `<` opens a part that holds no tag,
    /// or `nil` when it opens a tag.
    private static func skip(from open: String.Index, in xml: String) -> String.Index? {
        let rest = xml[open...]
        if rest.hasPrefix("<!--") {
            return end(of: "-->", after: open, in: xml)
        }
        if rest.hasPrefix("<![CDATA[") {
            return end(of: "]]>", after: open, in: xml)
        }
        if rest.hasPrefix("<?") {
            return end(of: "?>", after: open, in: xml)
        }
        if rest.hasPrefix("<!") {
            return end(of: ">", after: open, in: xml)
        }
        return nil
    }

    private static func end(
        of marker: String, after open: String.Index, in xml: String
    ) -> String.Index {
        guard let range = xml.range(of: marker, range: open..<xml.endIndex) else {
            return xml.endIndex
        }
        return range.upperBound
    }

    /// The five entities XML defines.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return
            text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
