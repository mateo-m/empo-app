import XCTest

@testable import GameProbe

final class AccountHintMaskTests: XCTestCase {

    func testAnEmailKeepsOnlyTheFirstLettersOfEachPart() {
        XCTAssertEqual(
            AccountHintMask.masked("jo.walker@gmail.com", provider: .googleDrive),
            "jo••••@gm••••.c••••")
        XCTAssertEqual(
            AccountHintMask.masked("sam@protonmail.com", provider: .dropbox),
            "sa••••@pr••••.c••••")
        XCTAssertEqual(
            AccountHintMask.masked("ana@mail.example.co.uk", provider: .dropbox),
            "a••••@ma••••.ex••••.c••••.u••••")
    }

    func testAShortNameShowsOneLetterAndHidesItsLength() {
        XCTAssertEqual(AccountHintMask.masked("abc@x.com", provider: .dropbox), "a••••@x••••.c••••")
        XCTAssertEqual(AccountHintMask.masked("a@x.com", provider: .dropbox), "a••••@x••••.c••••")
    }

    func testAWebDAVUserNameHidesAndItsHostStays() {
        XCTAssertEqual(
            AccountHintMask.masked("tester at 127.0.0.1", provider: .webdav), "te•••• at 127.0.0.1")
        XCTAssertEqual(AccountHintMask.masked("tester", provider: .webdav), "te••••")
    }

    func testAHintThatNamesNoPersonHasNothingToHide() {
        XCTAssertNil(AccountHintMask.masked("this account", provider: .dropbox))
        XCTAssertNil(AccountHintMask.masked("this device", provider: .iCloudDrive))
        XCTAssertNil(AccountHintMask.masked("empo-live at 127.0.0.1", provider: .s3))
    }
}
