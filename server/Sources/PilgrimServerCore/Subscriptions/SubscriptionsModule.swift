import Vapor

/// Subscriptions module — owned by task S8 (openspec/changes/add-private-groups/tasks.md).
///
/// `POST /api/v1/subscriptions/verify`, `GET /me/entitlement`, `POST /api/appstore/notifications` (on `routes.root`), the entitlement middleware and the `subscriptions` worker job.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum SubscriptionsModule {
    static func register(_ app: Application) throws {
    }
}
