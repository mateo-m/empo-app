import Foundation

/// What the target screen draws for usage, per SPEC 13.6 and 13.8.
///
/// Every provider uses one layout. A row that cannot be filled is
/// absent, with one exception: a missing usage bar reads as a
/// loading failure, so a target that answers no space query shows
/// the bytes Empo itself wrote and says why.
public enum TargetUsage: Equatable, Sendable {
    /// A bar, against the cap the user set or against the provider
    /// quota.
    case bar(usedBytes: Int64, limitBytes: Int64)
    /// No number governs. The bytes Empo wrote here.
    case bytesWritten(Int64)
}

public enum TargetUsageRules {

    /// The usage the target screen shows.
    ///
    /// The order is the one 13.8 states: the cap the user set, then
    /// the provider quota, then the bytes written.
    ///
    /// Quota is a per-target probe result and not a per-provider
    /// constant, per 9.7. The add check and the re-sign-in check
    /// refresh it, and Empo never polls it. A target that answered
    /// once and later stops answering arrives here with a nil
    /// reading and falls back to the bytes written, with no error.
    public static func usage(
        reading: QuotaReading?, capBytes: Int64?, bytesWrittenHere: Int64
    ) -> TargetUsage {
        // The cap limits what Empo stores, so the cap bar counts
        // Empo's own bytes. The provider bar counts the whole
        // account, because that is what fills the account up.
        if let capBytes {
            return .bar(usedBytes: bytesWrittenHere, limitBytes: capBytes)
        }
        if let reading, let limit = reading.limitBytes {
            return .bar(usedBytes: reading.usedBytes, limitBytes: limit)
        }
        return .bytesWritten(bytesWrittenHere)
    }

    /// The line under the bar, or the line that stands in for it.
    ///
    /// `usedText` and `limitText` carry the byte counts in the words
    /// the caller formatted, such as "2.4 GB".
    public static func line(
        _ usage: TargetUsage, usedText: String, limitText: String = ""
    ) -> String {
        switch usage {
        case .bar:
            return "\(usedText) of \(limitText) used"
        case .bytesWritten:
            return "\(usedText) backed up here. \(TargetCapabilities.noSpaceQueryLine)"
        }
    }
}
