import Foundation

extension Data {
    /// Decodes bytes as text with a UTF-8-then-Latin-1 fallback.
    /// This applies to Game.ini, loose `.rb` scripts, and similar
    /// files. RPG Maker tools write them in Windows-1252 / Latin-1,
    /// but the files often open as UTF-8 too.
    ///
    /// Latin-1 maps every byte 0x00-0xFF to U+0000-U+00FF, so the
    /// fallback always succeeds. The returned String just may not
    /// match what a user typed in non-Western text. That is fine
    /// for the parsing we do (ini key=value pairs, ASCII Ruby
    /// keywords). Text that goes to the UI as-is should still pass
    /// through a proper encoding detector.
    public func decodeAsLooseText() -> String? {
        String(data: self, encoding: .utf8)
            ?? String(data: self, encoding: .isoLatin1)
    }
}
