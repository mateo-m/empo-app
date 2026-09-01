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

    public func clearCheckpoint(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM run_checkpoint WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - Dirty flags

    public func markDirty(gameKey: String, reason: String, at date: Date) throws {
        try database.run(
            """
            INSERT INTO dirty_game (gameKey, markedAt, reason) VALUES (?, ?, ?)
            ON CONFLICT (gameKey) DO UPDATE SET
                markedAt = excluded.markedAt, reason = excluded.reason
            """,
            [.text(gameKey), .real(date.timeIntervalSince1970), .text(reason)])
    }

    public func dirtyGames() throws -> [DirtyMark] {
        let rows = try database.query(
            "SELECT gameKey, markedAt, reason FROM dirty_game ORDER BY markedAt, gameKey")
        return rows.compactMap { row in
            guard let gameKey = row[0].string,
                let markedAt = row[1].double,
                let reason = row[2].string
            else { return nil }
            return DirtyMark(
                gameKey: gameKey,
                markedAt: Date(timeIntervalSince1970: markedAt),
                reason: reason)
        }
    }

    public func clearDirty(gameKey: String) throws {
        try database.run("DELETE FROM dirty_game WHERE gameKey = ?", [.text(gameKey)])
    }

    // MARK: - The scheduler's own state, per SPEC 7.10 and 7.11

    /// The keys `scheduler_state` holds.
    private enum SchedulerKey: String {
        /// The consecutive runs lost to a force quit, per 7.10.
        case interruptedRunTally = "interrupted-run-tally"
        /// The notifications already posted, per 7.11. A key that
        /// leaves the list arms its cause again.
        case notificationLedger = "notification-ledger"
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

    public func notificationLedger() throws -> BackupNotificationLedger {
        guard let text = try schedulerValue(.notificationLedger), !text.isEmpty else {
            return BackupNotificationLedger()
        }
        return BackupNotificationLedger(
            postedKeys: Set(text.split(separator: "\n").map(String.init)))
    }

    public func saveNotificationLedger(_ ledger: BackupNotificationLedger) throws {
        try setSchedulerValue(
            ledger.postedKeys.sorted().joined(separator: "\n"), for: .notificationLedger)
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
                run.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(run.outcome.rawValue), .integer(run.uploadedBytes),
                .integer(Int64(run.gameCount)),
                run.detail.map { .text($0) } ?? .null,
            ])
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
                let outcome = row[4].string.flatMap(BackupRunOutcome.init(rawValue:)),
                let uploadedBytes = row[5].int64,
                let gameCount = row[6].int64
            else { return nil }
            return BackupRunRecord(
                id: id,
                targetId: targetId,
                startedAt: Date(timeIntervalSince1970: startedAt),
                finishedAt: row[3].double.map { Date(timeIntervalSince1970: $0) },
                outcome: outcome,
                uploadedBytes: uploadedBytes,
                gameCount: Int(gameCount),
                detail: row[7].string)
        }
    }

    /// Drops the rows past the 90-day retention of 6.6. The clock is
    /// a parameter, so the rule is testable.
    @discardableResult
    public func pruneRunHistory(now: Date) throws -> Int {
        let cutoff = now.addingTimeInterval(-BackupRunRecord.retention)
        try database.run(
            "DELETE FROM run_record WHERE startedAt < ?",
            [.real(cutoff.timeIntervalSince1970)])
        return try changeCount()
    }

    // MARK: - Intent records

    public func saveIntent(_ intent: BackupIntentRecord) throws {
        try database.run(
            """
            INSERT INTO intent_record
                (kind, targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                 restoreScope, replacesTree, createdAt, asked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind) DO UPDATE SET
                targetId = excluded.targetId,
                gameKey = excluded.gameKey,
                snapshotId = excluded.snapshotId,
                uploadedBytes = excluded.uploadedBytes,
                remainingBytes = excluded.remainingBytes,
                restoreScope = excluded.restoreScope,
                replacesTree = excluded.replacesTree,
                createdAt = excluded.createdAt,
                asked = excluded.asked
            """,
            [
                .text(intent.kind.rawValue), .text(intent.targetId),
                intent.gameKey.map { .text($0) } ?? .null,
                intent.snapshotId.map { .text($0) } ?? .null,
                .integer(intent.uploadedBytes),
                .integer(intent.remainingBytes),
                intent.restoreScope.map { .text($0.rawValue) } ?? .null,
                .integer(intent.replacesTheTree ? 1 : 0),
                .real(intent.createdAt.timeIntervalSince1970),
                .integer(intent.asked ? 1 : 0),
            ])
    }

    public func intent(kind: BackupIntentKind) throws -> BackupIntentRecord? {
        let rows = try database.query(
            """
            SELECT targetId, gameKey, snapshotId, uploadedBytes, remainingBytes,
                   restoreScope, replacesTree, createdAt, asked
            FROM intent_record WHERE kind = ?
            """,
            [.text(kind.rawValue)])
        guard let row = rows.first,
            let targetId = row[0].string,
            let uploadedBytes = row[3].int64,
            let remainingBytes = row[4].int64,
            let replacesTree = row[6].int64,
            let createdAt = row[7].double,
            let asked = row[8].int64
        else { return nil }
        return BackupIntentRecord(
            kind: kind,
            targetId: targetId,
            gameKey: row[1].string,
            snapshotId: row[2].string,
            uploadedBytes: uploadedBytes,
            remainingBytes: remainingBytes,
            restoreScope: row[5].string.flatMap(RestoreScope.init(rawValue:)),
            replacesTheTree: replacesTree != 0,
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
}
