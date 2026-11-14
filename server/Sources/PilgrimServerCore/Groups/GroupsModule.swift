import Vapor

/// Groups module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/**` except invites and votes: CRUD, leave, members, bans, admin transfer, seen, notification settings.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum GroupsModule {
    static func register(_ app: Application) throws {
    }
}
