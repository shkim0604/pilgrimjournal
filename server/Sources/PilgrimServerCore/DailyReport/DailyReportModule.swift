import Foundation
import PilgrimAPI
import Vapor

/// DailyReport module — owned by task S7 (openspec/changes/add-private-groups/tasks.md).
///
/// `GET /api/v1/me/daily-report` and the `dailyReport` worker job.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum DailyReportModule {
    /// The `dailyReport` loop period (design.md "worker"; never scaled).
    static let interval: Duration = .seconds(60)

    static func register(_ app: Application) throws {
        // Group content: 402 while `SUBSCRIPTION_REQUIRED` is on and the user is not entitled.
        app.pilgrimRoutes.groupMember.get("me", "daily-report", use: getReport)
        app.workerJobs.register(job())
    }

    /// Built fresh per application.
    static func job() -> WorkerJob {
        WorkerJob(name: "dailyReport", lockKey: WorkerLockKey.dailyReport, interval: interval) {
            context in
            try await DailyReportSweep.run(
                on: context.db, config: context.config, now: context.now, logger: context.logger)
        }
    }

    /// `GET /me/daily-report?date=YYYY-MM-DD` → `DailyReportResponse`. Without `date`, the most
    /// recently ended window (today once today's report time has passed, else yesterday). Days
    /// that were never sent are computed the same way.
    @Sendable static func getReport(_ req: Request) async throws -> Response {
        let user = try await req.currentUser()
        let now = Date()
        let zone = DailyReportSchedule.timeZone(user.timeZone)
        let date: LocalDate
        if let raw = req.query[String.self, at: "date"], !raw.isEmpty {
            guard let parsed = LocalDate(raw) else {
                throw APIError.validationFailed(field: "date", "date must be YYYY-MM-DD")
            }
            date = parsed
        } else {
            date = DailyReportSchedule.latestReportDate(
                now: now, minute: user.dailyReportMinute, timeZone: zone)
        }
        let report = try await DailyReportBuilder(db: req.db, config: req.pilgrimConfig)
            .report(
                for: try user.requireID(), date: date, minute: user.dailyReportMinute,
                timeZone: zone, now: now)
        return try .pilgrimJSON(report)
    }
}
