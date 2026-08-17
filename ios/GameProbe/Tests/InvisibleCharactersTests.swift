import XCTest

@testable import GameProbe

final class InvisibleCharactersTests: XCTestCase {

    private let vs16 = "\u{FE0F}"
    private let vs15 = "\u{FE0E}"
    private let vs17 = "\u{E0100}"

    // MARK: - Stripping

    func testPlainTextIsUntouched() {
        XCTAssertEqual("Pokemon Empyrean".strippingInvisibleVariants(), "Pokemon Empyrean")
        XCTAssertEqual("".strippingInvisibleVariants(), "")
    }

    func testSelectorAfterALetterIsRemoved() {
        XCTAssertEqual("Poke\(vs16)mon".strippingInvisibleVariants(), "Pokemon")
        XCTAssertEqual("a\(vs15)b\(vs17)c".strippingInvisibleVariants(), "abc")
    }

    func testSelectorAfterASpaceOrPunctuationIsRemoved() {
        XCTAssertEqual("Game \(vs16)Two".strippingInvisibleVariants(), "Game Two")
        XCTAssertEqual("Game:\(vs16) Two".strippingInvisibleVariants(), "Game: Two")
    }

    /// The attack shape from the study: a selector after roughly
    /// every third character. It must fold back to the clean title.
    func testDenseInsertionFoldsBackToTheOriginal() {
        let clean = "Pokemon Empyrean"
        var attacked = ""
        for (index, character) in clean.enumerated() {
            attacked.append(character)
            if index.isMultiple(of: 3) { attacked += vs16 }
        }
        XCTAssertNotEqual(attacked, clean)
        XCTAssertEqual(attacked.strippingInvisibleVariants(), clean)
    }

    func testALeadingSelectorWithNoBaseIsRemoved() {
        XCTAssertEqual("\(vs16)Game".strippingInvisibleVariants(), "Game")
    }

    func testRepeatedSelectorsAllGo() {
        XCTAssertEqual("A\(vs16)\(vs16)\(vs16)B".strippingInvisibleVariants(), "AB")
    }

    // MARK: - What must survive

    func testEmojiPresentationSelectorSurvives() {
        // U+2764 U+FE0F is the red heart. Without the selector it
        // renders as an outline glyph, so the player sees a change.
        let heart = "\u{2764}\(vs16)"
        XCTAssertEqual(heart.strippingInvisibleVariants(), heart)
    }

    func testTextPresentationSelectorSurvives() {
        let textHeart = "\u{2764}\(vs15)"
        XCTAssertEqual(textHeart.strippingInvisibleVariants(), textHeart)
    }

    func testCJKVariantSelectorSurvives() {
        // U+8FBB with a supplementary selector is a named kanji
        // variant, common in Japanese titles.
        let kanji = "\u{8FBB}\(vs17)"
        XCTAssertEqual(kanji.strippingInvisibleVariants(), kanji)
    }

    func testKeycapSequenceSurvives() {
        // A digit takes a selector only in a keycap sequence.
        let keycap = "1\(vs16)\u{20E3}"
        XCTAssertEqual(keycap.strippingInvisibleVariants(), keycap)
        // The same digit with a bare selector is the attack shape.
        XCTAssertEqual("1\(vs16)0".strippingInvisibleVariants(), "10")
    }

    func testIdempotent() {
        let input = "Poke\(vs16)mon \u{2764}\(vs16) Ver\(vs15)2"
        let once = input.strippingInvisibleVariants()
        XCTAssertEqual(once.strippingInvisibleVariants(), once)
    }

    // MARK: - Folder names

    func testSanitizeFoldsInvisibleTitlesTogether() {
        let clean = GameFolderName.sanitize("Pokemon Empyrean")
        let attacked = GameFolderName.sanitize("Poke\(vs16)mon Empy\(vs16)rean")
        XCTAssertEqual(attacked, clean)
    }

    /// A selector must not become a space. That would split a word
    /// that the player reads as one.
    func testSelectorDoesNotBecomeASpace() {
        XCTAssertEqual(GameFolderName.sanitize("Poke\(vs16)mon"), "Pokemon")
    }

    func testSanitizeStaysIdempotentWithSelectors() {
        let once = GameFolderName.sanitize("Poke\(vs16)mon\(vs17)")
        XCTAssertEqual(GameFolderName.sanitize(once), once)
    }

    func testATitleOfOnlySelectorsFallsBack() {
        XCTAssertEqual(GameFolderName.sanitize("\(vs16)\(vs17)"), GameFolderName.fallback)
    }

    // MARK: - Reuse of an existing directory

    /// An install from before this change holds its saves under a
    /// name with the selector in it. The clean name must find it
    /// instead of creating a second directory next to it.
    func testExistingDirectoryWithASelectorIsReused() {
        let onDisk = "Poke\(vs16)mon Empyrean"
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("Pokemon Empyrean", among: [onDisk]),
            onDisk)
    }

    func testAVerbatimMatchStillWinsOverTheSelectorVariant() {
        let clean = "Pokemon Empyrean"
        let onDisk = ["Poke\(vs16)mon Empyrean", clean]
        XCTAssertEqual(DirectoryNameMatch.preferringExisting(clean, among: onDisk), clean)
    }

    func testNoMatchKeepsTheCleanName() {
        XCTAssertEqual(
            DirectoryNameMatch.preferringExisting("Pokemon Empyrean", among: ["Other Game"]),
            "Pokemon Empyrean")
    }
}
