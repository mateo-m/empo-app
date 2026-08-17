import Foundation

/// Removal of characters that take space in a string but draw
/// nothing on screen.
///
/// A game title reaches Empo from the game's INI file, and that file
/// is often hand-edited or pasted from a web page. Text from those
/// places can carry invisible characters. Two titles that a player
/// reads as the same name are then different strings, and Empo
/// derives a container folder name and a save directory from the
/// title. The library ends up with two cards that look identical,
/// and the second one cannot find the first one's saves.
///
/// `GameFolderName` already turns format characters (Unicode
/// category Cf: zero-width space, zero-width joiner, the bidi
/// controls, the byte-order mark) into spaces. Variation selectors
/// are the gap. They sit in category Mn, so no control-character
/// set catches them, and Unicode normalization keeps them on
/// purpose.
///
/// A variation selector is not always noise. After an emoji base it
/// picks the color or the text shape, and after a CJK ideograph it
/// picks a glyph variant. Both change what the player sees, so this
/// code keeps those. It removes a selector only after a base that
/// can never take one: a plain letter, a digit, a space, or
/// punctuation from the Latin range.
public enum InvisibleCharacters {

    /// Variation selectors 1 to 16.
    static let variationSelectors: ClosedRange<UInt32> = 0xFE00...0xFE0F

    /// Variation selectors 17 to 256, in the supplementary plane.
    static let supplementarySelectors: ClosedRange<UInt32> = 0xE0100...0xE01EF

    /// Mongolian free variation selectors, plus the vowel separator.
    static let mongolianSelectors: ClosedRange<UInt32> = 0x180B...0x180E

    /// Combining enclosing keycap. A digit or a hash followed by a
    /// selector and this mark is a keycap emoji, so the selector
    /// belongs to the sequence.
    static let keycap: UInt32 = 0x20E3

    static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return variationSelectors.contains(value)
            || supplementarySelectors.contains(value)
            || mongolianSelectors.contains(value)
    }

    /// True when a variation selector after `base` changes what the
    /// reader sees. Emoji bases and East Asian characters qualify.
    /// Everything else does not.
    static func takesVariationSelector(_ base: Unicode.Scalar) -> Bool {
        let value = base.value
        // Emoji live from the symbol blocks upward. A letter, a
        // digit, or Latin punctuation never carries a selector.
        if value >= 0x1F000 { return true }
        if value >= 0x2E80 { return true }
        switch base.properties.generalCategory {
        case .otherSymbol, .mathSymbol, .modifierSymbol:
            return base.properties.isEmoji
        default:
            return false
        }
    }
}

extension String {

    /// The string without the variation selectors that draw
    /// nothing. Emoji and CJK variants keep theirs.
    ///
    /// The result reads the same as the input for any human. Two
    /// titles that a player cannot tell apart therefore produce one
    /// folder name and one save directory.
    public func strippingInvisibleVariants() -> String {
        guard unicodeScalars.contains(where: InvisibleCharacters.isVariationSelector) else {
            return self
        }
        let scalars = Array(unicodeScalars)
        var kept = String.UnicodeScalarView()
        var previousKept: Unicode.Scalar?
        for (index, scalar) in scalars.enumerated() {
            guard InvisibleCharacters.isVariationSelector(scalar) else {
                kept.append(scalar)
                previousKept = scalar
                continue
            }
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            let isKeycap = next?.value == InvisibleCharacters.keycap
            let base = previousKept
            if isKeycap || (base.map(InvisibleCharacters.takesVariationSelector) ?? false) {
                kept.append(scalar)
                // The selector is not a base for the next one.
            }
        }
        return String(kept)
    }
}
