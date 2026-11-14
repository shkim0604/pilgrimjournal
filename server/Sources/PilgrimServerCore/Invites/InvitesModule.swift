import Vapor

/// Invites module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/:id/invites`, `GET /invites/:code`, `POST /invites/:code/accept` (conditional UPDATE).
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum InvitesModule {
    static func register(_ app: Application) throws {
    }
}
