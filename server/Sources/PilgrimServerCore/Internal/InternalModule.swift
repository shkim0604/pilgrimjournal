import Vapor

/// Internal module — owned by task S4 (openspec/changes/add-private-groups/tasks.md).
///
/// Operator routes on `routes.admin` (`/internal/admin/v1/*`): the `X-Admin-Token` / `Cf-Ray` guard first, then reports, deletions, suspensions, media and status.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum InternalModule {
    static func register(_ app: Application) throws {
    }
}
