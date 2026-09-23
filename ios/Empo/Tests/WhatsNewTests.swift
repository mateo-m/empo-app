import XCTest

@testable import Empo

final class WhatsNewTests: XCTestCase {
    private func release(_ version: Int, _ titles: String...) -> WhatsNewRelease {
        WhatsNewRelease(
            version: version,
            items: titles.map { WhatsNewItem(symbol: "star", title: $0, detail: "") }
        )
    }

    func testSkippedReleasesShowTogetherNewestFirst() {
        let releases = [release(2, "b"), release(3, "c"), release(1, "a")]

        let titles = WhatsNew.items(after: 1, in: releases).map(\.title)

        XCTAssertEqual(titles, ["c", "b"])
    }

    func testNothingShowsAfterTheLatestRelease() {
        XCTAssertTrue(WhatsNew.items(after: WhatsNew.version).isEmpty)
    }

    func testEveryReleaseHasItsOwnVersion() {
        let versions = WhatsNew.releases.map(\.version)

        XCTAssertEqual(Set(versions).count, versions.count)
    }
}
