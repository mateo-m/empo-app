import Foundation
import XCTest

/// Skips a check that the host cannot run, unless skips are forbidden.
///
/// A few checks need something the host may not have: a legacy text
/// encoding, or POSIX permission bits that root ignores. They skip by
/// default, so the suite runs anywhere. A skip is silent, though, and
/// the Linux runner skips every legacy-encoding check. Set
/// `EMPO_TESTS_NO_SKIP=1` to make each of these skips a failure. CI
/// sets it on the macOS job, so no check can go missing on all runners
/// at the same time.
func skipOrFail(
    _ reason: String, file: StaticString = #filePath, line: UInt = #line
) throws -> Never {
    if ProcessInfo.processInfo.environment["EMPO_TESTS_NO_SKIP"] == "1" {
        XCTFail("this host cannot run the check: \(reason)", file: file, line: line)
    }
    throw XCTSkip(reason, file: file, line: line)
}
