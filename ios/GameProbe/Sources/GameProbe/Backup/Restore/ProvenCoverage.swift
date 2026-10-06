import Foundation

/// The replace path of SPEC 11.12, and the proof that gates it.
///
/// The replace choice is the one place bytes leave the container, and
/// it is gated on proof and never on judgement. Empo drops a file
/// from the replaced tree only when the game is in full mode **and**
/// the file is matched by hash inside a snapshot that is readable at
/// that moment. Everything else stays on disk.
///
/// This type reads hashes and nothing else. The save classifier never
/// reaches it, and it never may: the classifier reads the game root
/// only and skips `data`, `graphics`, `audio`, `fonts`, `system`, and
/// `movies`, so a game that writes `Game/data/save.rxdata` is
/// invisible to it, and a false negative would delete a player's
/// save. That is invariant 3.
///
/// For a slim-mode game a replace therefore keeps most of the
/// replaced tree. That is the honest price of rolling back a game the
/// user chose not to upload. The escape is the one-off full snapshot
/// of 5.15, which makes the whole tree provably covered and lets it
/// clear itself.
public enum ProvenCoverage {

    /// One file of the tree a replace moved aside.
    public struct TreeFile: Equatable, Sendable {

        /// The path inside the replaced tree.
        public var path: String
        public var hash: String
        public var sizeBytes: Int64

        public init(path: String, hash: String, sizeBytes: Int64) {
            self.path = path
            self.hash = hash
            self.sizeBytes = sizeBytes
        }
    }

    /// What a replace may drop, and what stays.
    public struct Decision: Equatable, Sendable {

        /// The paths with proven coverage. Only these leave.
        public var drop: [String]
        /// Everything else. It stays on disk, and the user deletes it
        /// by hand behind a confirmation that names what goes.
        public var keep: [String]
        public var keptBytes: Int64

        public init(drop: [String] = [], keep: [String] = [], keptBytes: Int64 = 0) {
            self.drop = drop
            self.keep = keep
            self.keptBytes = keptBytes
        }

        /// Whether the replaced tree clears itself whole.
        public var clearsItself: Bool {
            keep.isEmpty
        }
    }

    /// What a replace drops from the tree it moved aside.
    ///
    /// - `mode`: the game's mode. Anything but full drops nothing.
    /// - `readableSnapshot`: a snapshot Empo could read at this
    ///   moment. `nil` means it could not, and then nothing drops.
    public static func decide(
        mode: BackupMode,
        treeFiles: [TreeFile],
        readableSnapshot: SnapshotManifest?
    ) -> Decision {
        guard mode == .full, let snapshot = readableSnapshot else {
            return Decision(
                drop: [], keep: treeFiles.map(\.path),
                keptBytes: treeFiles.reduce(0) { $0 + $1.sizeBytes })
        }

        let covered = Set(snapshot.entries.map(\.hash))
        var decision = Decision()
        for file in treeFiles {
            if covered.contains(file.hash) {
                decision.drop.append(file.path)
            } else {
                decision.keep.append(file.path)
                decision.keptBytes += file.sizeBytes
            }
        }
        return decision
    }

    // MARK: - The warning, and the escape of 5.15

    /// Whether the replace warning offers the one-off full snapshot,
    /// per 5.15.
    ///
    /// A full-mode game needs no offer, because its next readable
    /// snapshot already covers the tree.
    public static func offersOneOffFullSnapshot(mode: BackupMode) -> Bool {
        mode != .full
    }

    /// The line the replace warning carries for a slim-mode game.
    public static let slimReplaceLine =
        "This game backs up its saves only, so the files it does not back up stay on this device "
        + "after the replace. You can open them later."

    /// The escape the warning offers.
    public static let oneOffFullSnapshotLabel = "Back up all of this game's files first"
}
