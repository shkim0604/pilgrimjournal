import Vapor

/// Account module — owned by task S1 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/me` (GET, PATCH, DELETE), `me/devices/:installationId`. Also the `SIGNUP_REQUIRED` / `ACCOUNT_SUSPENDED` middleware other modules put on their groups.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum AccountModule {
    static func register(_ app: Application) throws {
    }
}
