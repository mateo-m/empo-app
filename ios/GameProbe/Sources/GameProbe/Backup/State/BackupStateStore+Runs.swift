import Foundation

/// What one run leaves behind: the checkpoint it can continue
/// from, the games it must cover next, the history row, and the
/// intent record a process death leaves.
extension BackupStateStore {

    // MARK: - Checkpoints

    public func saveCheckpoint(_ checkpoint: RunCheckpoint) throws {
        try database.run(
            """
            INSERT INTO run_checkpoint
                (targetId, gameKey, snapshotId, uploadedBytes, pendingPaths,
                 confirmedBlobs, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                pendingPaths = excluded.pendingPaths,
                confirmedBlobs = excluded.confirmedBlobs,
                updatedAt = excluded.updatedAt
            """,
            [
                .text(checkpoint.targetId), .text(checkpoint.gameKey),
                .text(checkpoint.snapshotId), .integer(checkpoint.uploadedBytes),
                .text(Self.encodeList(checkpoint.pendingPaths)),
                .text(Self.encodeList(checkpoint.confirmedBlobs.map(\.text))),
                .real(checkpoint.updatedAt.timeIntervalSince1970),
            ])
    }

    public func checkpoint(targetId: String, gameKey: String) throws -> RunCheckpoint? {
        let rows = try database.query(
            """
            SELECT snapshotId, uploadedBytes, pendingPaths, confirmedBlobs, updatedAt
            FROM run_checkpoint WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        guard let row = rows.first,
            let snapshotId = row[0].string,
            let uploadedBytes = row[1].int64,
            let paths = row[2].string,
            let blobs = row[3].string,
            let updatedAt = row[4].double
        else { return nil }
        return RunCheckpoint(
            targetId: targetId,
            gameKey: gameKey,
            snapshotId: snapshotId,
            uploadedBytes: uploadedBytes,
            pendingPaths: Self.decodeList(paths),
            confirmedBlobs: Self.decodeList(blobs).compactMap(ConfirmedBlob.init(text:)),
            updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    /// Every blob hash the checkpoints of one target name.
    public func checkpointBlobHashes(targetId: String) throws -> Set<String> {
        let rows = try database.query(
            "SELECT confirmedBlobs FROM run_checkpoint WHERE targetId = ?",
            [.text(targetId)])
        return Set(
            rows.flatMap { row in
                Self.decodeList(row[0].string ?? "[]").compactMap { ConfirmedBlob(text: $0)?.hash }
            })
    }

    public func clearCheckpoint(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM run_checkpoint WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - Dirty flags

    /// Marks the game on each target in `targetIds`.
    public func markDirty(gameKey: String, targetIds: [String], at date: Date) throws {
        try database.transaction {
            for targetId in targetIds {
                try database.run(
                    """
                    INSERT INTO dirty_game (targetId, gameKey, markedAt) VALUES (?, ?, ?)
                    ON CONFLICT (targetId, gameKey) DO UPDATE SET markedAt = excluded.markedAt
                    """,
                    [.text(targetId), .text(gameKey), .real(date.timeIntervalSince1970)])
            }
        }
    }

    public func dirtyGames() throws -> [DirtyMark] {
        let rows = try database.query(
            "SELECT targetId, gameKey, markedAt FROM dirty_game ORDER BY markedAt, gameKey, targetId")
        return rows.compactMap { row in
            guard let targetId = row[0].string,
                let gameKey = row[1].string,
                let markedAt = row[2].double
            else { return nil }
            return DirtyMark(
                targetId: targetId, gameKey: gameKey,
                markedAt: Date(timeIntervalSince1970: markedAt))
        }
    }

    /// A mark after `date` came from a play the run did not read, so
    /// it stays for the next pass.
    public func clearDirty(targetId: String, gameKey: String, markedUpTo date: Date) throws {
        try database.run(
            "DELETE FROM dirty_game WHERE targetId = ? AND gameKey = ? AND markedAt <= ?",
            [.text(targetId), .text(gameKey), .real(date.timeIntervalSince1970)])
    }

    // MARK: - The scheduler's own state, per SPEC 7.10 and 7.11

    /// The keys `scheduler_state` holds.
    private enum SchedulerKey: String {
        /// The consecutive runs lost to a force quit, per 7.10.
        case interruptedRunTally = "interrupted-run-tally"
    }

    private func schedulerValue(_ key: SchedulerKey) throws -> String? {
        let rows = try database.query(
            "SELECT value FROM scheduler_state WHERE key = ?", [.text(key.rawValue)])
        return rows.first?[0].string
    }

    private func setSchedulerValue(_ value: String, for key: SchedulerKey) throws {
        try database.run(
            """
            INSERT INTO scheduler_state (key, value) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value
            """,
            [.text(key.rawValue), .text(value)])
    }

    public func interruptedRunTally() throws -> InterruptedRunTally {
        let text = try schedulerValue(.interruptedRunTally) ?? "0"
        return InterruptedRunTally(count: Int(text) ?? 0)
    }

    public func saveInterruptedRunTally(_ tally: InterruptedRunTally) throws {
        try setSchedulerValue(String(tally.count), for: .interruptedRunTally)
    }

    // MARK: - The notifications already posted, per SPEC 7.11

    public func notificationLedger() throws -> BackupNotificationLedger {
        let rows = try database.query("SELECT cause, targetId FROM posted_notification")
        return BackupNotificationLedger(
            posted: Set(
                rows.compactMap { row in
                    BackupFailFastCause(rawValue: row[0].string ?? "").map {
                        BackupNotificationLedger.Posted(cause: $0, targetId: row[1].string)
                    }
                }))
    }

    public func saveNotificationLedger(_ ledger: BackupNotificationLedger) throws {
        try database.transaction {
            try database.run("DELETE FROM posted_notification")
            for entry in ledger.posted {
                try database.run(
                    "INSERT INTO posted_notification (cause, targetId) VALUES (?, ?)",
                    [.text(entry.cause.rawValue), entry.targetId.map { .text($0) } ?? .null])
            }
        }
    }

    // MARK: - The partial-path clock of SPEC 7.2

    /// How many consecutive runs each save member came back partial
    /// on, for one game on one target.
    public func partialTally(targetId: String, gameKey: String) throws -> [String: Int] {
        let rows = try database.query(
            "SELECT path, runs FROM partial_tally WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
        var tally: [String: Int] = [:]
        for row in rows {
            guard let path = row[0].string, let runs = row[1].int64 else { continue }
            tally[path] = Int(runs)
        }
        return tally
    }

    /// Replaces the whole tally for one game on one target.
    ///
    /// It replaces rather than merges, because the count is
    /// consecutive: a path the run no longer reports partial must
    /// lose its count, per 7.2.
    public func savePartialTally(
        _ tally: [String: Int], targetId: String, gameKey: String
    ) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM partial_tally WHERE targetId = ? AND gameKey = ?",
                [.text(targetId), .text(gameKey)])
            for (path, runs) in tally.sorted(by: { $0.key < $1.key }) {
                try database.run(
                    """
                    INSERT INTO partial_tally (targetId, gameKey, path, runs)
                    VALUES (?, ?, ?, ?)
                    """,
                    [.text(targetId), .text(gameKey), .text(path), .integer(Int64(runs))])
            }
        }
    }

    // MARK: - Run history

    public func recordRun(_ run: BackupRunRecord) throws {
        try database.run(
            """
            INSERT INTO run_record
                (id, targetId, startedAt, finishedAt, outcome, uploadedBytes,
                 gameCount, detail)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET
                finishedAt = excluded.finishedAt,
                outcome = excluded.outcome,
                uploadedBytes = excluded.uploadedBytes,
                gameCount = excluded.gameCount,
                detail = excluded.detail
            """,
            [
                .text(run.id), .text(run.targetId),
                .real(run.startedAt.timeIntervalSince1970),
                run.end.map { .real($0.finishedAt.timeIntervalSince1970) } ?? .null,
                run.end.map { .text($0.outcome.rawValue) } ?? .null,
                .integer(run.uploadedBytes),
                .integer(Int64(run.gameCount)),
                run.end?.detail.map { .text($0) } ?? .null,
            ])
        let cutoff = run.startedAt.addingTimeInterval(-BackupRunRecord.retention)
        try database.run(
            "DELETE FROM run_record WHERE startedAt < ?",
            [.real(cutoff.timeIntervalSince1970)])
    }

    /// The whole history, newest first. One global list, per 6.6.
    public func runHistory() throws -> [BackupRunRecord] {
        let rows = try database.query(
            """
            SELECT id, targetId, startedAt, finishedAt, outcome, uploadedBytes,
                   gameCount, detail
            FROM run_record ORDER BY startedAt DESC, id DESC
            """)
        return rows.compactMap { row in
            guard let id = row[0].string,
                let targetId = row[1].string,
                let startedAt = row[2].double,
                let uploadedBytes = row[5].int64,
                let gameCount = row[6].int64
            else { return nil }
            var end: BackupRunEnd?
            if let finishedAt = row[3].double {
                guard let outcome = row[4].string.flatMap(BackupRunOutcome.init(rawValue:))
                else { return nil }
                end = BackupRunEnd(
                    outcome: outcome, finishedAt: Date(timeIntervalSince1970: finishedAt),
                    detail: row[7].string)
            }
            return BackupRunRecord(
                id: id,
                targetId: targetId,
                startedAt: Date(timeIntervalSince1970: startedAt),
                end: end,
                uploadedBytes: uploadedBytes,
                gameCount: Int(gameCount))
        }
    }

    // MARK: - Intent records

    public func saveIntent(_ intent: BackupIntentRecord) throws {
        var uploadedBytes: Int64 = 0
        var remainingBytes: Int64 = 0
        var choice: RestoreChoice?
        var movedAsideTree: String?
        switch intent.work {
        case .run(let uploaded, let remaining):
            uploadedBytes = uploaded
            remainingBytes = remaining
        case .restore(let restoreChoice, let moved):
            choice = restoreChoice
            movedAsideTree = moved
        }
        try database.run(
            """
            INSERT INTO intent_record
                (kind, targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                 restoreScope, replacesTree, movedAsideTree, createdAt, asked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind) DO UPDATE SET
                targetId = excluded.targetId,
                gameKey = excluded.gameKey,
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                remainingBytes = excluded.remainingBytes,
                restoreScope = excluded.restoreScope,
                replacesTree = excluded.replacesTree,
                movedAsideTree = excluded.movedAsideTree,
                createdAt = excluded.createdAt,
                asked = excluded.asked
            """,
            [
                .text(intent.kind.rawValue), .text(intent.targetId),
                intent.gameKey.map { .text($0) } ?? .null,
                intent.snapshotId.map { .text($0) } ?? .null,
                .integer(uploadedBytes),
                .integer(remainingBytes),
                choice.map { .text($0.scope.rawValue) } ?? .null,
                .integer(choice == .replaceTheTree ? 1 : 0),
                movedAsideTree.map { .text($0) } ?? .null,
                .real(intent.createdAt.timeIntervalSince1970),
                .integer(intent.asked ? 1 : 0),
            ])
    }

    public func intent(kind: BackupIntentKind) throws -> BackupIntentRecord? {
        let rows = try database.query(
            """
            SELECT targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                   restoreScope, replacesTree, movedAsideTree, createdAt, asked
            FROM intent_record WHERE kind = ?
            """,
            [.text(kind.rawValue)])
        guard let row = rows.first,
            let targetId = row[0].string,
            let uploadedBytes = row[3].int64,
            let remainingBytes = row[4].int64,
            let replacesTree = row[6].int64,
            let createdAt = row[8].double,
            let asked = row[9].int64
        else { return nil }
        let work: BackupIntentRecord.Work
        switch kind {
        case .interruptedRun:
            work = .run(uploadedBytes: uploadedBytes, remainingBytes: remainingBytes)
        case .interruptedRestore:
            guard let scope = row[5].string.flatMap(RestoreScope.init(rawValue:)) else { return nil }
            work = .restore(
                replacesTree != 0 ? .replaceTheTree : .restore(scope),
                movedAsideTree: row[7].string)
        }
        return BackupIntentRecord(
            targetId: targetId,
            gameKey: row[1].string,
            snapshotId: row[2].string,
            work: work,
            createdAt: Date(timeIntervalSince1970: createdAt),
            asked: asked != 0)
    }

    /// Records that the user saw the question. The same interruption
    /// never asks twice, per 6.5.
    public func markIntentAsked(kind: BackupIntentKind) throws {
        try database.run(
            "UPDATE intent_record SET asked = 1 WHERE kind = ?", [.text(kind.rawValue)])
    }

    public func clearIntent(kind: BackupIntentKind) throws {
        try database.run(
            "DELETE FROM intent_record WHERE kind = ?", [.text(kind.rawValue)])
    }

    /// Clears the interrupted-run record only when it names this
    /// stream, so a closed stream leaves no record that names it.
    public func clearInterruptedRun(targetId: String, streamKey: String) throws {
        try database.run(
            "DELETE FROM intent_record WHERE kind = ? AND targetId = ? AND gameKey = ?",
            [.text(BackupIntentKind.interruptedRun.rawValue), .text(targetId), .text(streamKey)])
    }
}
