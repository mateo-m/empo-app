import Foundation

/// What one target owes and what its row shows: the deletes it
/// has not been told about, the staleness clocks, the last
/// failure and space answer, and the sweep clock.
extension BackupStateStore {

    // MARK: - Pending deletions

    public func addPendingDeletion(_ deletion: PendingDeletion) throws {
        try database.run(
            """
            INSERT INTO pending_deletion
                (targetId, gameKey, requestedAt, rescuedBuckets)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                requestedAt = excluded.requestedAt,
                rescuedBuckets = excluded.rescuedBuckets
            """,
            [
                .text(deletion.targetId), .text(deletion.gameKey),
                .real(deletion.requestedAt.timeIntervalSince1970),
                .text(Self.encodeList(deletion.rescuedBuckets)),
            ])
    }

    public func pendingDeletions(targetId: String) throws -> [PendingDeletion] {
        let rows = try database.query(
            """
            SELECT gameKey, requestedAt, rescuedBuckets FROM pending_deletion
            WHERE targetId = ? ORDER BY requestedAt, gameKey
            """,
            [.text(targetId)])
        return rows.compactMap { row in
            guard let gameKey = row[0].string,
                let requestedAt = row[1].double,
                let buckets = row[2].string
            else { return nil }
            return PendingDeletion(
                targetId: targetId,
                gameKey: gameKey,
                requestedAt: Date(timeIntervalSince1970: requestedAt),
                rescuedBuckets: Self.decodeList(buckets))
        }
    }

    public func clearPendingDeletion(targetId: String, gameKey: String) throws {
        try database.run(
            "DELETE FROM pending_deletion WHERE targetId = ? AND gameKey = ?",
            [.text(targetId), .text(gameKey)])
    }

    // MARK: - Staleness clocks

    public func saveStaleness(_ clock: StalenessClock) throws {
        func value(_ date: Date?) -> SQLiteValue {
            date.map { .real($0.timeIntervalSince1970) } ?? .null
        }
        try database.run(
            """
            INSERT INTO staleness
                (targetId, gameKey, lastSuccessAt, lastAttemptAt, partialSince)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (targetId, gameKey) DO UPDATE SET
                lastSuccessAt = excluded.lastSuccessAt,
                lastAttemptAt = excluded.lastAttemptAt,
                partialSince = excluded.partialSince
            """,
            [
                .text(clock.targetId), .text(clock.gameKey),
                value(clock.lastSuccessAt), value(clock.lastAttemptAt),
                value(clock.partialSince),
            ])
    }

    public func staleness(targetId: String, gameKey: String) throws -> StalenessClock? {
        let rows = try database.query(
            """
            SELECT lastSuccessAt, lastAttemptAt, partialSince FROM staleness
            WHERE targetId = ? AND gameKey = ?
            """,
            [.text(targetId), .text(gameKey)])
        guard let row = rows.first else { return nil }
        func date(_ value: SQLiteValue) -> Date? {
            value.double.map { Date(timeIntervalSince1970: $0) }
        }
        return StalenessClock(
            targetId: targetId,
            gameKey: gameKey,
            lastSuccessAt: date(row[0]),
            lastAttemptAt: date(row[1]),
            partialSince: date(row[2]))
    }

    // MARK: - What the target row shows, per SPEC 13.5

    /// The last failure and the last space query answer of one
    /// target.
    ///
    /// The row outlives the run that produced it, so the row state
    /// of 13.5 lives here and not in the run.
    public func targetStatus(targetId: String) throws -> TargetStatusRecord? {
        let rows = try database.query(
            """
            SELECT failureKind, failureDetail, failedAt, quotaUsed, quotaLimit, quotaAt
            FROM target_status WHERE targetId = ?
            """,
            [.text(targetId)])
        guard let row = rows.first else { return nil }
        func date(_ value: SQLiteValue) -> Date? {
            value.double.map { Date(timeIntervalSince1970: $0) }
        }
        let quota = row[3].int64.map {
            QuotaReading(usedBytes: $0, limitBytes: row[4].int64)
        }
        return TargetStatusRecord(
            targetId: targetId,
            failure: TargetFailure(kind: row[0].string, detail: row[1].string ?? ""),
            failedAt: date(row[2]),
            quota: quota,
            quotaAt: date(row[5]))
    }

    /// Writes the failure the last run left, or clears it after a
    /// run that reached the target.
    public func recordTargetFailure(
        targetId: String, failure: TargetFailure?, at date: Date
    ) throws {
        let kind: SQLiteValue = failure.map { .text($0.kind) } ?? .null
        let detail: SQLiteValue = failure.map { .text($0.detail) } ?? .null
        let when: SQLiteValue = failure == nil ? .null : .real(date.timeIntervalSince1970)
        try database.run(
            """
            INSERT INTO target_status (targetId, failureKind, failureDetail, failedAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId) DO UPDATE SET
                failureKind = excluded.failureKind,
                failureDetail = excluded.failureDetail,
                failedAt = excluded.failedAt
            """,
            [.text(targetId), kind, detail, when])
    }

    /// Writes the space query answer of 9.7. The add check and the
    /// re-sign-in check are the only callers, because Empo never
    /// polls a quota.
    public func recordTargetQuota(
        targetId: String, reading: QuotaReading?, at date: Date
    ) throws {
        let used: SQLiteValue = reading.map { .integer($0.usedBytes) } ?? .null
        let limit: SQLiteValue = reading?.limitBytes.map { .integer($0) } ?? .null
        let when: SQLiteValue = reading == nil ? .null : .real(date.timeIntervalSince1970)
        try database.run(
            """
            INSERT INTO target_status (targetId, quotaUsed, quotaLimit, quotaAt)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (targetId) DO UPDATE SET
                quotaUsed = excluded.quotaUsed,
                quotaLimit = excluded.quotaLimit,
                quotaAt = excluded.quotaAt
            """,
            [.text(targetId), used, limit, when])
    }

    /// What Empo holds on one target, per game, biggest first.
    ///
    /// The newest manifest of each game names every file that game
    /// keeps there, so the sum is what the target holds now, not
    /// what every run ever uploaded.
    public func usage(targetId: String) throws -> [TargetGameUsage] {
        let rows = try database.query(
            "SELECT gameKey, manifest FROM uploaded_manifest WHERE targetId = ?",
            [.text(targetId)])
        var usage: [TargetGameUsage] = []
        for row in rows {
            guard let key = row[0].string, let payload = row[1].data,
                let manifest = try? SnapshotManifest.decode(json: payload)
            else { continue }
            usage.append(
                TargetGameUsage(
                    gameKey: key, bytes: manifest.entries.reduce(0) { $0 + $1.size }))
        }
        return usage.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.gameKey < $1.gameKey
        }
    }

    // MARK: - Maintenance clocks

    /// When the sweep of 5.11 last finished on this target.
    public func lastSweep(targetId: String) throws -> Date? {
        let rows = try database.query(
            "SELECT lastSweepAt FROM target_maintenance WHERE targetId = ?",
            [.text(targetId)])
        return rows.first?[0].double.map { Date(timeIntervalSince1970: $0) }
    }

    public func recordSweep(targetId: String, at date: Date) throws {
        try database.run(
            """
            INSERT INTO target_maintenance (targetId, lastSweepAt) VALUES (?, ?)
            ON CONFLICT (targetId) DO UPDATE SET lastSweepAt = excluded.lastSweepAt
            """,
            [.text(targetId), .real(date.timeIntervalSince1970)])
    }
}
