import Foundation
import XCTest

@testable import GameProbe

final class SaveRecoveryLedgerTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_755_000_000)

    func testMergingAppendsNewNames() {
        let ledger = SaveRecoveryLedger.merging([], name: "Nova", files: ["Game.rxdata"], date: day)

        XCTAssertEqual(
            ledger,
            [.init(name: "Nova", files: ["Game.rxdata"], date: day)])
    }

    func testMergingUnionsFilesAndKeepsTheFirstDate() {
        let later = day.addingTimeInterval(600)
        var ledger = SaveRecoveryLedger.merging(
            [], name: "Nova", files: ["Game.rxdata"], date: day)
        ledger = SaveRecoveryLedger.merging(
            ledger, name: "Nova", files: ["Game.rxdata", "Game1.rxdata"], date: later)

        XCTAssertEqual(
            ledger,
            [.init(name: "Nova", files: ["Game.rxdata", "Game1.rxdata"], date: day)])
    }

    func testMergingWithNothingNewReturnsTheInputUnchanged() {
        let ledger = [SaveRecoveryLedger.Record(name: "Nova", files: ["Game.rxdata"], date: day)]

        XCTAssertEqual(
            SaveRecoveryLedger.merging(ledger, name: "Nova", files: ["Game.rxdata"], date: day),
            ledger)
    }

    func testMergingKeepsOtherRecordsIntact() {
        var ledger = SaveRecoveryLedger.merging([], name: "Anil", files: ["Game.rxdata"], date: day)
        ledger = SaveRecoveryLedger.merging(ledger, name: "Nova", files: ["Game2.rxdata"], date: day)
        ledger = SaveRecoveryLedger.merging(ledger, name: "Anil", files: ["Game3.rxdata"], date: day)

        XCTAssertEqual(
            ledger,
            [
                .init(name: "Anil", files: ["Game.rxdata", "Game3.rxdata"], date: day),
                .init(name: "Nova", files: ["Game2.rxdata"], date: day),
            ])
    }

    func testEncodeDecodeRoundTrip() throws {
        let ledger = [
            SaveRecoveryLedger.Record(name: "Nova", files: ["Game.rxdata", "Game.rxdata.bak"], date: day),
            SaveRecoveryLedger.Record(name: "Pokémon Empyrean", files: ["Game1.rxdata"], date: day),
        ]

        let blob = try XCTUnwrap(SaveRecoveryLedger.encode(ledger))
        XCTAssertEqual(SaveRecoveryLedger.decode(blob), ledger)
    }

    func testEncodeIsDeterministic() throws {
        let ledger = [SaveRecoveryLedger.Record(name: "Nova", files: ["Game.rxdata"], date: day)]

        XCTAssertEqual(
            try XCTUnwrap(SaveRecoveryLedger.encode(ledger)),
            try XCTUnwrap(SaveRecoveryLedger.encode(ledger)))
    }

    func testDecodeToleratesGarbageAndNil() {
        XCTAssertEqual(SaveRecoveryLedger.decode(nil), [])
        XCTAssertEqual(SaveRecoveryLedger.decode(Data("not json".utf8)), [])
    }
}
