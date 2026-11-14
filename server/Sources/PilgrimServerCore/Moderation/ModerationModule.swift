import Vapor

/// Moderation module — owned by task S4 (openspec/changes/add-private-groups/tasks.md).
///
/// Blocks, hides (`/api/v1/me/blocks`, `me/hides`), `POST /reports` with snapshots and the report webhook.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum ModerationModule {
    static func register(_ app: Application) throws {
    }
}
