import Foundation
import XCTest

/// Skips a check that the host cannot run, unless skips are forbidden.
///
/// A skip is silent, so a check that skips on every runner looks like
/// a check that passes. Set `EMPO_TESTS_NO_SKIP=1` to make each of
/// these skips a failure. CI sets it on the macOS job, which has the
/// engine submodule that the vendored-header check needs.
func skipOrFail(
    _ reason: String, file: StaticString = #filePath, line: UInt = #line
) throws -> Never {
    if ProcessInfo.processInfo.environment["EMPO_TESTS_NO_SKIP"] == "1" {
        XCTFail("this host cannot run the check: \(reason)", file: file, line: line)
    }
    throw XCTSkip(reason, file: file, line: line)
}
