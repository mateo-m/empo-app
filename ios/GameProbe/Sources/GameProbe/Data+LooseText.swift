import Foundation

extension Data {
    /// Decodes bytes as text: UTF-8 first, then Shift-JIS or
    /// Windows-1252, then Latin-1. This applies to Game.ini, loose
    /// `.rb` scripts, and similar files.
    ///
    /// UTF-8 is strict, so valid UTF-8 (including pure ASCII) never
    /// reaches the fallbacks. The hard case is a file that is valid
    /// in both legacy encodings at once. Western titles collide
    /// with Shift-JIS often: in "Pokémon" the Windows-1252 bytes
    /// for "é" (0xE9) and "m" (0x6D) form one valid Shift-JIS
    /// kanji, 駑. A blind Shift-JIS-first chain therefore turns
    /// "Pokémon Empyrean" into "Pok駑on Empyrean", and the INI
    /// title names both the game's container and its shared data
    /// directory. The engine decodes the same file with a real
    /// encoding detector (uchardet), so a mojibake title here puts
    /// Empo's directories out of step with what the game displays.
    ///
    /// The tiebreak uses structure instead of byte validity alone:
    ///
    ///   1. Full-width kana in the Shift-JIS decode means Japanese
    ///      text. Windows-1252 titles almost never produce
    ///      full-width kana, because kana needs a 0x82/0x83 lead
    ///      byte ("‚"/"ƒ"), and those are rare in Western text.
    ///      A run of half-width kana counts too, but only a run:
    ///      one half-width kana is what a stray accented capital
    ///      (0xA1-0xDF) decodes to.
    ///   2. Otherwise, prefer Windows-1252 when every non-ASCII
    ///      character it yields is plausible in Western text: a
    ///      letter, a combining mark, a space, or common
    ///      punctuation. Kanji-heavy input fails this test because
    ///      its lead bytes land on Windows-1252 symbols like "•"
    ///      and "†".
    ///   3. Otherwise, keep the Shift-JIS decode.
    ///
    /// Latin-1 stays as the last resort: it maps every byte, so
    /// the function only returns nil for input no candidate can
    /// represent, which Latin-1 never is.
    public func decodeAsLooseText() -> String? {
        if let utf8 = String(data: self, encoding: .utf8) {
            return utf8
        }

        let shiftJIS = String(data: self, encoding: .shiftJIS)
        if let shiftJIS, Self.looksJapanese(shiftJIS) {
            return shiftJIS
        }

        if let cp1252 = String(data: self, encoding: .windowsCP1252),
            Self.looksWestern(cp1252)
        {
            return cp1252
        }

        return shiftJIS ?? String(data: self, encoding: .isoLatin1)
    }

    private static func looksJapanese(_ text: String) -> Bool {
        var halfWidthRun = 0
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value) {
                return true
            }
            if (0xFF66...0xFF9F).contains(scalar.value) {
                halfWidthRun += 1
                if halfWidthRun >= 3 { return true }
            } else {
                halfWidthRun = 0
            }
        }
        return false
    }

    /// Punctuation and signs that appear in Western titles and INI
    /// text. Smart double quotes stay out: their Windows-1252
    /// bytes (0x93/0x94) are common kanji lead bytes, and straight
    /// quotes dominate in INI files anyway.
    private static let westernPunctuation = Set<Unicode.Scalar>(
        "’–—…€°©®™«»¡¿·±¢£¥§¶".unicodeScalars
    )

    private static func looksWestern(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            if scalar.isASCII { return true }
            switch scalar.properties.generalCategory {
            case .lowercaseLetter, .uppercaseLetter, .titlecaseLetter,
                .modifierLetter, .otherLetter,
                .nonspacingMark, .spacingMark, .enclosingMark,
                .spaceSeparator:
                return true
            default:
                return westernPunctuation.contains(scalar)
            }
        }
    }
}
