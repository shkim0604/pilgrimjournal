import Vapor

/// Posts module — owned by task S3 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/:id/posts`, `posts/:id` (detail, delete, extend), comments, reactions. Use `ContentVisibility` for every read and `PushOutbox.enqueue(on:post:)` in the create transaction.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum PostsModule {
    static func register(_ app: Application) throws {
    }
}
