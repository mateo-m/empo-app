import Foundation
import XCTest

@testable import GameProbe

final class ImportNameResolutionTests: XCTestCase {

    private func context(
        installed: [String] = [],
        inFlight: [String] = [],
        open: String? = nil
    ) -> ImportNameResolution.Context {
        ImportNameResolution.Context(
            installedFolderNames: installed,
            inFlightNames: inFlight,
            openGameName: open
        )
    }

    func testUniqueTitleIsFreshWithSanitizedName() {
        var batch = Set<String>()
        let outcome = ImportNameResolution.resolve(
            title: "  Pokémon   Z  ", context: context(), reservedBatchKeys: &batch)
        XCTAssertEqual(outcome, .fresh(folderName: "Pokémon Z"))
        XCTAssertTrue(batch.contains("pokémon z"))
    }

    func testInstalledMatchBecomesUpdateWithInstalledCasing() {
        var batch = Set<String>()
        let outcome = ImportNameResolution.resolve(
            title: "TESTING",
            context: context(installed: ["Testing"]),
            reservedBatchKeys: &batch)
        XCTAssertEqual(outcome, .update(installedFolderName: "Testing"))
    }

    func testSanitizedTitleMatchesInstalledName() {
        // The installed copy was imported as "Fate Another" (the
        // sanitizer stripped the slash); a re-import of the raw
        // title must still match it.
        var batch = Set<String>()
        let outcome = ImportNameResolution.resolve(
            title: "Fate/Another",
            context: context(installed: ["Fate Another"]),
            reservedBatchKeys: &batch)
        XCTAssertEqual(outcome, .update(installedFolderName: "Fate Another"))
    }

    func testInFlightNameIsRefusedEvenWhenInstalled() {
        var batch = Set<String>()
        let outcome = ImportNameResolution.resolve(
            title: "Testing",
            context: context(installed: ["Testing"], inFlight: ["Testing"]),
            reservedBatchKeys: &batch)
        XCTAssertEqual(outcome, .refusedInFlight)
        XCTAssertTrue(batch.isEmpty)
    }

    func testOpenGameUpdateIsRefusedAndNotReserved() {
        var batch = Set<String>()
        let first = ImportNameResolution.resolve(
            title: "Testing",
            context: context(installed: ["Testing"], open: "Testing"),
            reservedBatchKeys: &batch)
        XCTAssertEqual(first, .refusedOpenGame)
        XCTAssertTrue(batch.isEmpty)

        // A retry in the same batch is refused the same way, not
        // silently downgraded to a fresh install.
        let second = ImportNameResolution.resolve(
            title: "Testing",
            context: context(installed: ["Testing"], open: "Testing"),
            reservedBatchKeys: &batch)
        XCTAssertEqual(second, .refusedOpenGame)
    }

    func testSecondFreshSelectionWithSameTitleIsRefused() {
        var batch = Set<String>()
        let ctx = context()
        XCTAssertEqual(
            ImportNameResolution.resolve(
                title: "Testing", context: ctx, reservedBatchKeys: &batch),
            .fresh(folderName: "Testing"))
        XCTAssertEqual(
            ImportNameResolution.resolve(
                title: "testing", context: ctx, reservedBatchKeys: &batch),
            .refusedDuplicateInBatch)
    }

    func testSecondSelectionAfterUpdateIsRefused() {
        var batch = Set<String>()
        let ctx = context(installed: ["Testing"])
        XCTAssertEqual(
            ImportNameResolution.resolve(
                title: "Testing", context: ctx, reservedBatchKeys: &batch),
            .update(installedFolderName: "Testing"))
        XCTAssertEqual(
            ImportNameResolution.resolve(
                title: "Testing", context: ctx, reservedBatchKeys: &batch),
            .refusedDuplicateInBatch)
    }

    func testDistinctTitlesDoNotInterfere() {
        var batch = Set<String>()
        let ctx = context(installed: ["Testing"], open: "Testing")
        XCTAssertEqual(
            ImportNameResolution.resolve(
                title: "Another Game", context: ctx, reservedBatchKeys: &batch),
            .fresh(folderName: "Another Game"))
    }

    func testOpenGameOnlyBlocksItsOwnUpdate() {
        // A DIFFERENT installed game being open must not block this
        // update.
        var batch = Set<String>()
        let outcome = ImportNameResolution.resolve(
            title: "Testing",
            context: context(installed: ["Testing", "Other"], open: "Other"),
            reservedBatchKeys: &batch)
        XCTAssertEqual(outcome, .update(installedFolderName: "Testing"))
    }
}
