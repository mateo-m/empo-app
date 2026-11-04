import Foundation

/// What the engine tells the screen while a run happens, per SPEC
/// 13.2.
///
/// The engine owns the run plan. The pill, the card badge, and the
/// run block read it and never compute a second one. A run with no
/// observer behaves exactly as it did before.
///
/// `streamKey` is `BackupStream.key`, so the caller reads the game
/// back with `BackupStream(key:)`.
public protocol BackupRunObserver: Sendable {

    /// One stream starts to stage: the engine reads and hashes its
    /// files before it knows what to upload.
    func runStages(streamKey: String) async

    /// One stream froze its part of the plan: every blob this
    /// snapshot needs. The engine reports every stream before the
    /// first upload, and the number never changes again for this run.
    func runPlanned(streamKey: String, bytes: Int64) async

    /// One stream starts to upload its part of the plan.
    func runUploads(streamKey: String) async

    /// One blob is on the target, because the provider confirmed the
    /// upload or because the local cache proves the blob is already
    /// there.
    func runConfirmed(streamKey: String, bytes: Int64) async

    /// One blob of the plan starts to upload. Until its
    /// `runConfirmed`, the only upload in flight is this blob's.
    func runSendsBlob(bytes: Int64) async

    /// Asked before each game stream and before each of its files.
    /// `false` stops the run with
    /// `BackupRunStop.gameStarted`, per 7.6.
    func runMayGoOn() async -> Bool
}

extension BackupRunObserver {
    public func runStages(streamKey: String) async {}
    public func runUploads(streamKey: String) async {}
    public func runSendsBlob(bytes: Int64) async {}
    public func runMayGoOn() async -> Bool { true }
}
