import Vapor

/// Account module — owned by task S1 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/me` (GET, PATCH, DELETE), `me/devices/:installationId` (`AccountRoutes`). Other
/// modules put their routes on `app.pilgrimRoutes.signedUp` (`AccountStateMiddleware`:
/// 401 for a deleted account, 403 `ACCOUNT_SUSPENDED`, 403 `SIGNUP_REQUIRED`) and read the user
/// with `req.currentUser()`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum AccountModule {
    static func register(_ app: Application) throws {
        AccountRoutes.register(app)
    }
}
