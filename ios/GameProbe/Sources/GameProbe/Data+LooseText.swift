import Foundation

extension Data {
    /// Decode bytes as text using a UTF-8-then-Latin-1 fallback.
    /// Used for Game.ini, loose `.rb` scripts, and similar files
    /// that RPG Maker tools write in Windows-1252 / Latin-1 but
    /// are often editable as UTF-8 too.
    ///
    /// Latin-1 maps every byte 0x00-0xFF to U+0000-U+00FF, so the
    /// fallback always succeeds; the returned String just won't
    /// match what a user typed in non-Western text. That's fine
    /// for the parsing we do (ini key=value pairs, ASCII Ruby
    /// keywords), but text passed verbatim to UI should still go
    /// through a proper encoding detector.
    public func decodeAsLooseText() -> String? {
        String(data: self, encoding: .utf8)
            ?? String(data: self, encoding: .isoLatin1)
    }
}
