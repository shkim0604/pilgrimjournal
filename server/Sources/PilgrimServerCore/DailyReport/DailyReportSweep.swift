import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// The `dailyReport` worker loop (design.md "worker", 11절): every user whose report time has
/// passed today in their own zone and who has no `daily_report_log` row for today gets the day's
/// report built; an empty one is logged `skipped`, anything else is logged `sent` and queued in
/// `push_outbox` in the same transaction.
///
/// Candidates are users with `daily_report_enabled`, a finished sign-up, no suspension and at
/// least one group whose Daily Report they keep on. `UNIQUE(user_id, report_date)` makes a second
/// worker (or a retry after a crash) a no-op for a date already logged.
public enum DailyReportSweep {
    /// Reports built per iteration; the rest wait for the next one (60 s later).
    public static let batchSize = 200

    public struct Candidate: Equatable, Sendable {
        public var userID: UUID
        public var timeZone: String
        public var minute: Int
        public var lastReportDate: LocalDate?
        public var suspendedAt: Date?
        public var suspendedUntil: Date?

        public init(
            userID: UUID, timeZone: String, minute: Int, lastReportDate: LocalDate? = nil,
            suspendedAt: Date? = nil, suspendedUntil: Date? = nil
        ) {
            self.userID = userID
            self.timeZone = timeZone
            self.minute = minute
            self.lastReportDate = lastReportDate
            self.suspendedAt = suspendedAt
            self.suspendedUntil = suspendedUntil
        }

        /// Same rule as `User.isSuspended(at:)`.
        public func isSuspended(at now: Date) -> Bool {
            guard suspendedAt != nil else { return false }
            guard let suspendedUntil else { return true }
            return suspendedUntil > now
        }
    }

    public struct Due: Equatable, Sendable {
        public var userID: UUID
        public var date: LocalDate
        public var minute: Int
        public var timeZone: TimeZone
    }

    public struct Outcome: Equatable, Sendable {
        public var sent = 0
        public var skipped = 0
    }

    /// The candidates whose report is due at `now`, at most `limit`, in candidate order.
    public static func due(_ candidates: [Candidate], now: Date, limit: Int = batchSize) -> [Due] {
        var result: [Due] = []
        for candidate in candidates where !candidate.isSuspended(at: now) {
            guard result.count < limit else { break }
            let zone = DailyReportSchedule.timeZone(candidate.timeZone)
            guard
                let date = DailyReportSchedule.dueReportDate(
                    now: now, minute: candidate.minute, timeZone: zone,
                    lastReportDate: candidate.lastReportDate)
            else { continue }
            result.append(
                Due(userID: candidate.userID, date: date, minute: candidate.minute, timeZone: zone))
        }
        return result
    }

    /// One iteration. A user whose report fails is logged and left for the next iteration; the
    /// first such error is rethrown at the end so `worker_heartbeat` records it.
    @discardableResult
    public static func run(
        on db: any Database, config: AppConfig, now: Date, logger: Logger
    ) async throws -> Outcome {
        let due = due(try await candidates(on: db), now: now)
        var outcome = Outcome()
        var firstError: (any Error)?
        for item in due {
            do {
                switch try await deliver(item, on: db, config: config, now: now) {
                case .sent?: outcome.sent += 1
                case .skipped?: outcome.skipped += 1
                case nil: break
                }
            } catch {
                logger.error(
                    "daily report failed",
                    metadata: ["user": "\(item.userID)", "error": "\(String(reflecting: error))"])
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return outcome
    }

    /// Builds, logs and (when not empty) queues one report. Returns nil when the date was already
    /// logged by someone else.
    static func deliver(_ item: Due, on db: any Database, config: AppConfig, now: Date)
        async throws -> DailyReportLogEntry.Status?
    {
        let window = DailyReportSchedule.window(
            on: item.date, minute: item.minute, in: item.timeZone)
        let report = try await DailyReportBuilder(db: db, config: config)
            .report(for: item.userID, date: item.date, window: window, now: now)
        let status: DailyReportLogEntry.Status = report.totalCount == 0 ? .skipped : .sent
        return try await db.transaction { tx in
            let sql = try PushOutbox.sqlDatabase(tx)
            let inserted = try await sql.raw(
                """
                INSERT INTO daily_report_log
                    (id, user_id, report_date, window_start, window_end, status, item_count,
                     created_at)
                VALUES (\(bind: UUID()), \(bind: item.userID), \(bind: item.date.description),
                    \(bind: window.start), \(bind: window.end), \(bind: status.rawValue),
                    \(bind: report.totalCount), \(bind: now))
                ON CONFLICT (user_id, report_date) DO NOTHING
                RETURNING id
                """
            ).first()
            guard inserted != nil else { return nil }
            if status == .sent {
                try await PushOutbox.enqueue(
                    on: tx, recipients: [item.userID],
                    payload: .dailyReport(itemCount: report.totalCount),
                    collapseID: collapseID(for: item.date), now: now)
            }
            return status
        }
    }

    /// One report per date on the lock screen even if it were queued twice.
    public static func collapseID(for date: LocalDate) -> String {
        "daily-report-\(date.description)"
    }

    /// Users who could get a report, with their latest logged date.
    static func candidates(on db: any Database) async throws -> [Candidate] {
        let sql = try PushOutbox.sqlDatabase(db)
        let rows = try await sql.raw(
            """
            SELECT u.id, u.time_zone, u.daily_report_minute, u.suspended_at, u.suspended_until,
                (SELECT MAX(l.report_date) FROM daily_report_log AS l WHERE l.user_id = u.id)
                    AS last_report_date
            FROM users AS u
            WHERE u.daily_report_enabled AND u.display_name IS NOT NULL
              AND EXISTS (SELECT 1 FROM memberships AS m
                  WHERE m.user_id = u.id AND m.daily_report_enabled)
            ORDER BY u.id
            """
        ).all()
        return try rows.map { row in
            Candidate(
                userID: try row.decode(column: "id", as: UUID.self),
                timeZone: try row.decode(column: "time_zone", as: String.self),
                minute: try row.decode(column: "daily_report_minute", as: Int.self),
                lastReportDate: try row.decode(column: "last_report_date", as: String?.self)
                    .flatMap(LocalDate.init),
                suspendedAt: try row.decode(column: "suspended_at", as: Date?.self),
                suspendedUntil: try row.decode(column: "suspended_until", as: Date?.self))
        }
    }
}
