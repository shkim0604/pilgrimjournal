import Vapor

/// Stickers module — owned by task S6 (openspec/changes/add-private-groups/tasks.md).
///
/// `GET`/`POST /api/v1/groups/:id/stickers`, `DELETE /api/v1/stickers/:id` (design.md 8절).
/// `StickerService.delete(_:on:)` removes a sticker with its reactions, photo and file, leaving
/// the comments that used it marked "지워진 스티커".
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum StickersModule {
    static func register(_ app: Application) throws {
        // Same account gate as the other group routes: signed up, not suspended, subscribed when
        // subscriptions are required.
        let routes = app.pilgrimRoutes.groupMember
        StickerRoutes.register(routes)
    }
}
