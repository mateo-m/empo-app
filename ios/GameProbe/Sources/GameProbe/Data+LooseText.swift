import Foundation

extension Data {
    /// Decodes bytes as text: UTF-8, then Shift-JIS, then Latin-1.
    /// This applies to Game.ini, loose `.rb` scripts, and similar
    /// files.
    ///
    /// Shift-JIS sits between the two because RPG Maker XP/VX ship
    /// from Japan and Japanese fan games write their INI titles in
    /// it - and the INI title now names both the game's container
    /// and its shared data directory. The engine decodes the same
    /// file with a real encoding detector (uchardet), so a
    /// mojibake title here would put Empo's directories out of
    /// step with what the game displays. ASCII content is valid
    /// UTF-8 and never reaches the fallback; bytes that are
    /// neither valid UTF-8 nor valid Shift-JIS land on Latin-1,
    /// which maps every byte and therefore always succeeds.
    public func decodeAsLooseText() -> String? {
        String(data: self, encoding: .utf8)
            ?? String(data: self, encoding: .shiftJIS)
            ?? String(data: self, encoding: .isoLatin1)
    }
}
