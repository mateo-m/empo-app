import Foundation

/// The run plan of SPEC 13.2.
///
/// Staging ends by producing it: every blob this snapshot needs,
/// minus every blob the local cache proves present. **That sum
/// freezes for the life of the run.** Each blob the provider
/// confirms adds its own size to the progress.
///
/// One stream plans once. A file that changes after that joins the
/// next snapshot and never inflates this one.
public struct BackupRunPlan: Equatable, Sendable {

    private var plannedByStream: [String: Int64] = [:]
    private var confirmedByStream: [String: Int64] = [:]
    public private(set) var confirmedBytes: Int64 = 0
    /// The stream the run uploads now.
    public private(set) var streamKey: String?

    public init() {}

    /// Freezes one stream's part of the plan. A second call for the
    /// same stream changes nothing.
    public mutating func plan(streamKey: String, bytes: Int64) {
        self.streamKey = streamKey
        guard plannedByStream[streamKey] == nil else { return }
        plannedByStream[streamKey] = bytes
    }

    public mutating func confirm(streamKey: String, bytes: Int64) {
        self.streamKey = streamKey
        confirmedByStream[streamKey, default: 0] += bytes
        confirmedBytes += bytes
    }

    public var plannedBytes: Int64 {
        plannedByStream.values.reduce(0, +)
    }

    public var bytesLeft: Int64 {
        max(0, plannedBytes - confirmedBytes)
    }

    /// A run with nothing to upload never shows the pill, per 13.2.
    public var hasUploads: Bool { plannedBytes > 0 }

    /// `nil` until the first stream freezes its plan. The badge and
    /// the pill draw a spinner until then, per 13.3.
    public var fraction: Double? {
        guard plannedBytes > 0 else { return nil }
        return min(1, Double(confirmedBytes) / Double(plannedBytes))
    }

    /// How far one stream is, for the card badge of 13.3.
    public func fraction(ofStream key: String) -> Double? {
        guard let planned = plannedByStream[key], planned > 0 else { return nil }
        return min(1, Double(confirmedByStream[key] ?? 0) / Double(planned))
    }

    /// Whether one stream has every blob of its plan on the target.
    public func isDone(_ key: String) -> Bool {
        guard let planned = plannedByStream[key] else { return false }
        return (confirmedByStream[key] ?? 0) >= planned
    }
}
