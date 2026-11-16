import Vapor

/// Posts module — owned by task S3 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/:id/posts`, `posts/:id` (detail, delete, extend), comments, reactions
/// (design.md "글·댓글·반응"). Every read goes through `ContentVisibility`; a new post queues its
/// pushes with `PushOutbox.enqueue(on:post:)` in the create transaction.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
///
/// Path parameters are all named `id` (`groups/:id/posts`, `posts/:id`, `comments/:id`) so they
/// never conflict with the other modules' routes in the shared router.
enum PostsModule {
    static func register(_ app: Application) throws {
        // Same account gate as the Groups routes: signed up, not suspended, subscribed when
        // subscriptions are required.
        let routes = app.pilgrimRoutes.groupMember
        PostRoutes.register(routes)
        CommentRoutes.register(routes)
        ReactionRoutes.register(routes)
    }
}
