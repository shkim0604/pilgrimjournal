import Vapor

/// DailyReport module — owned by task S7 (openspec/changes/add-private-groups/tasks.md).
///
/// `GET /api/v1/me/daily-report` and the `dailyReport` worker job.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum DailyReportModule {
    static func register(_ app: Application) throws {
    }
}
