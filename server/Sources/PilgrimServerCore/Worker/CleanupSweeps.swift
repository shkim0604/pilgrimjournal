import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// Shared helpers for the clean-up loops.
enum Sweep {
    static func sql(_ db: any Database) throws -> any SQLDatabase {
        try WorkerRunner.sql(db)
    }

    struct IDRow: Decodable {
        var id: UUID
    }

    /// Runs `batch` (one statement, so one transaction) until it removes fewer than `batchSize`
    /// rows or `maximumBatches` have run, and returns the total.
    static func repeatBatches(
        batchSize: Int, maximumBatches: Int = 20, _ batch: () async throws -> Int
    ) async throws -> Int {
        var total = 0
        for _ in 0..<maximumBatches {
            let removed = try await batch()
            total += removed
            if removed < batchSize { break }
        }
        return total
    }
}

/// `expiry` (60 s): deletes posts whose `expires_at` has passed, 500 at a time. The cascade
/// removes comments, reactions, extensions and media rows; `media_after_delete` queues the files.
public enum ExpirySweep {
    public static let batchSize = 500

    @discardableResult
    public static func run(on db: any Database, now: Date) async throws -> Int {
        let sql = try Sweep.sql(db)
        return try await Sweep.repeatBatches(batchSize: batchSize) {
            try await sql.raw(
                """
                DELETE FROM posts WHERE id IN (
                    SELECT id FROM posts WHERE expires_at <= \(bind: now)
                    ORDER BY expires_at, id LIMIT \(bind: batchSize))
                RETURNING id
                """
            ).all(decoding: Sweep.IDRow.self).count
        }
    }
}

/// `mediaFiles` (60 s): removes queued photo files and media rows that were never attached.
public enum MediaFileSweep {
    public static let batchSize = 100
    /// Uploads not attached within this long are deleted (design.md 7절). Real time, not
    /// scaled by `TIME_SCALE_DAY_SECONDS`.
    public static let unattachedLifetime: TimeInterval = 24 * 60 * 60
    /// A file that still cannot be removed after this many tries is given up on (logged).
    public static let maximumAttempts = 20

    public struct Summary: Equatable, Sendable {
        public var filesDeleted = 0
        public var filesFailed = 0
        public var unattachedDeleted = 0
    }

    @discardableResult
    public static func run(
        on db: any Database, store: any MediaStore, now: Date, logger: Logger
    ) async throws -> Summary {
        var summary = Summary()
        let sql = try Sweep.sql(db)

        // Unattached uploads first: their files join this pass's deletion queue via the trigger.
        let cutoff = now.addingTimeInterval(-unattachedLifetime)
        summary.unattachedDeleted = try await Sweep.repeatBatches(batchSize: 500) {
            try await sql.raw(
                """
                DELETE FROM media WHERE id IN (
                    SELECT id FROM media WHERE attached_at IS NULL AND created_at <= \(bind: cutoff)
                    ORDER BY created_at, id LIMIT 500)
                RETURNING id
                """
            ).all(decoding: Sweep.IDRow.self).count
        }

        struct QueueRow: Decodable {
            var id: UUID
            var filePath: String
            var attempts: Int

            enum CodingKeys: String, CodingKey {
                case id
                case filePath = "file_path"
                case attempts
            }
        }
        let queued = try await sql.raw(
            """
            SELECT id, file_path, attempts FROM media_file_deletions
            ORDER BY created_at, id LIMIT \(bind: batchSize)
            """
        ).all(decoding: QueueRow.self)
        for row in queued {
            do {
                try await store.delete(row.filePath)
                try await sql.raw("DELETE FROM media_file_deletions WHERE id = \(bind: row.id)")
                    .run()
                summary.filesDeleted += 1
            } catch let error as MediaStoreError {
                // A path that can never be valid: drop it rather than retry forever.
                logger.error(
                    "dropping invalid media file path",
                    metadata: ["id": "\(row.id)", "error": "\(error)"])
                try await sql.raw("DELETE FROM media_file_deletions WHERE id = \(bind: row.id)")
                    .run()
                summary.filesFailed += 1
            } catch {
                summary.filesFailed += 1
                if row.attempts + 1 >= maximumAttempts {
                    logger.error(
                        "giving up on media file deletion",
                        metadata: ["path": "\(row.filePath)", "error": "\(error)"])
                    try await sql.raw(
                        "DELETE FROM media_file_deletions WHERE id = \(bind: row.id)"
                    ).run()
                } else {
                    try await sql.raw(
                        """
                        UPDATE media_file_deletions SET attempts = attempts + 1
                        WHERE id = \(bind: row.id)
                        """
                    ).run()
                }
            }
        }
        return summary
    }
}

/// `invites` (1 h): deletes invites that expired more than seven days ago. Memberships keep
/// their row (`invite_id` becomes null).
public enum InviteSweep {
    public static let keepAfterExpiryDays: Double = 7

    @discardableResult
    public static func run(on db: any Database, now: Date, dayLength: TimeInterval) async throws
        -> Int
    {
        let sql = try Sweep.sql(db)
        let cutoff = now.addingTimeInterval(-keepAfterExpiryDays * dayLength)
        return try await Sweep.repeatBatches(batchSize: 1_000) {
            try await sql.raw(
                """
                DELETE FROM invites WHERE id IN (
                    SELECT id FROM invites WHERE expires_at <= \(bind: cutoff) LIMIT 1000)
                RETURNING id
                """
            ).all(decoding: Sweep.IDRow.self).count
        }
    }
}

/// `retention` (1 h): keeps operational tables from growing (design.md "worker"). These are
/// real-time retention periods; `TIME_SCALE_DAY_SECONDS` does not shorten them.
public enum RetentionSweep {
    static let day: TimeInterval = 86_400

    /// Delete rows of `table` whose `column` (a timestamp; null never matches) is older than
    /// `age`.
    public struct Rule: Sendable {
        public var table: String
        public var column: String
        public var age: TimeInterval
    }

    /// Reports (with their snapshots) are purged by the Moderation module (S4).
    public static let reportRetention: TimeInterval = 90 * day

    public static let rules: [Rule] = [
        Rule(table: "push_outbox", column: "sent_at", age: 7 * day),
        Rule(table: "push_outbox", column: "failed_at", age: 30 * day),
        Rule(table: "daily_report_log", column: "created_at", age: 30 * day),
        Rule(table: "appstore_notifications", column: "received_at", age: 90 * day),
        Rule(table: "refresh_tokens", column: "expires_at", age: 7 * day),
        Rule(table: "refresh_tokens", column: "revoked_at", age: 7 * day),
        // Revoked Apple tokens are useless once Apple confirmed; keep a week for diagnosis.
        Rule(table: "apple_token_revocations", column: "completed_at", age: 7 * day),
    ]

    /// Rows deleted per rule (`table.column`).
    @discardableResult
    public static func run(on db: any Database, now: Date) async throws -> [String: Int] {
        let sql = try Sweep.sql(db)
        var removed: [String: Int] = [:]
        removed["reports.created_at"] = try await ModerationService.purgeExpiredReportSnapshots(
            on: db, now: now, retention: reportRetention)
        for rule in rules {
            let cutoff = now.addingTimeInterval(-rule.age)
            let count = try await Sweep.repeatBatches(batchSize: 1_000) {
                try await sql.raw(
                    """
                    DELETE FROM \(ident: rule.table) WHERE id IN (
                        SELECT id FROM \(ident: rule.table)
                        WHERE \(ident: rule.column) <= \(bind: cutoff) LIMIT 1000)
                    RETURNING id
                    """
                ).all(decoding: Sweep.IDRow.self).count
            }
            removed["\(rule.table).\(rule.column)"] = count
        }
        return removed
    }
}
