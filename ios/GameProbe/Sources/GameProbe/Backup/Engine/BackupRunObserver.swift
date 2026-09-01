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

    /// One stream froze its part of the plan: every blob this
    /// snapshot needs. Staging ends by producing this number, and it
    /// never changes again for this run.
    func runPlanned(streamKey: String, bytes: Int64) async

    /// One blob is on the target, because the provider confirmed the
    /// upload or because the local cache proves the blob is already
    /// there.
    func runConfirmed(streamKey: String, bytes: Int64) async
}
