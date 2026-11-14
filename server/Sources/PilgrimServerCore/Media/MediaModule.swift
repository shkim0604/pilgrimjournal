import Vapor

/// Media module — owned by task S6 (openspec/changes/add-private-groups/tasks.md).
///
/// `POST /api/v1/uploads`, `GET /media/:id`, `GET /api/media-files/:id` (signed, on `routes.root`). Files go through `app.mediaStore`, URLs through `MediaURLSigner`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum MediaModule {
    static func register(_ app: Application) throws {
    }
}
