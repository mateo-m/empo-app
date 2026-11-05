import Foundation
import XCTest

@testable import GameProbe

/// The passes below come from `signPass` in `api/src/pass.ts`, signed
/// with a key made for this test only.
final class PlusPassTests: XCTestCase {

    private let publicKey = Data(base64Encoded: "lv8MNMW4DtAtq2iyjD+1w6PhBFUp1+oWs1uVNT5wvj0=")!
    private let plus =
        "eyJ2IjoxLCJzdWIiOiJ1c2VyLTEiLCJwbHVzIjp0cnVlLCJpYXQiOjE3OTM4MzY4MDAsImV4cCI6MTc5NDQ0MTYwMH0.SZZBJts_HuXxDsqtw6rjblvfI0AHL8JPtel9MYdoQsKPZJaA6hO1jSB81ctpLusnp_Au2uLuuHT7OmEmk_BJAw"
    private let free =
        "eyJ2IjoxLCJzdWIiOiJ1c2VyLTEiLCJwbHVzIjpmYWxzZSwiaWF0IjoxNzkzODM2ODAwLCJleHAiOjE3OTQ0NDE2MDB9.2o0AZ33bahSp7awHSanUx9Z8oQxkXMTWy22c2ht7JvVWGKpjZb4rrcSGg5pgYIXU_s7BT1Ijdfg-Plkm82XNDg"
    private let issuedAt = Date(timeIntervalSince1970: 1_793_836_800)
    private let day: TimeInterval = 24 * 60 * 60

    func testAPassFromTheAPIGrantsPlusForSevenDays() throws {
        let pass = try XCTUnwrap(PlusPass(plus, publicKey: publicKey))
        XCTAssertEqual(pass.userId, "user-1")
        XCTAssertEqual(pass.expiresAt, issuedAt.addingTimeInterval(7 * day))
        XCTAssertTrue(pass.grantsPlus(at: issuedAt))
        XCTAssertTrue(pass.grantsPlus(at: issuedAt.addingTimeInterval(7 * day - 1)))
        XCTAssertFalse(pass.grantsPlus(at: issuedAt.addingTimeInterval(7 * day)))
    }

    func testAPassForAnAccountWithoutPlusGrantsNothing() throws {
        let pass = try XCTUnwrap(PlusPass(free, publicKey: publicKey))
        XCTAssertFalse(pass.grantsPlus(at: issuedAt))
    }

    func testAPassAsksForRenewalWithThreeDaysLeft() throws {
        let pass = try XCTUnwrap(PlusPass(plus, publicKey: publicKey))
        XCTAssertFalse(pass.needsRenewal(at: issuedAt.addingTimeInterval(4 * day)))
        XCTAssertTrue(pass.needsRenewal(at: issuedAt.addingTimeInterval(4 * day + 1)))
    }

    func testAChangedPayloadFailsTheSignature() {
        let freeSignature = free.split(separator: ".")[1]
        let plusPayload = plus.split(separator: ".")[0]
        XCTAssertNil(PlusPass("\(plusPayload).\(freeSignature)", publicKey: publicKey))
    }

    func testAnotherKeyFailsTheSignature() {
        let other = Data(base64Encoded: "/Y4z9rhhNjRsPdXBEnhucGbDQDAuyMUupgqaPA+qTrA=")!
        XCTAssertNil(PlusPass(plus, publicKey: other))
    }

    func testTextThatIsNotAPassReadsAsNone() {
        XCTAssertNil(PlusPass("", publicKey: publicKey))
        XCTAssertNil(PlusPass("abc", publicKey: publicKey))
        XCTAssertNil(PlusPass("a.b.c", publicKey: publicKey))
    }
}
