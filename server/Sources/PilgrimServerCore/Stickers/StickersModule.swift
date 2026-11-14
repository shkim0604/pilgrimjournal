import Vapor

/// Stickers module — owned by task S6 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/:id/stickers`, `DELETE /stickers/:id`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum StickersModule {
    static func register(_ app: Application) throws {
    }
}
