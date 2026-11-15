import Vapor

/// Media module — owned by task S6 (openspec/changes/add-private-groups/tasks.md).
///
/// `POST /api/v1/uploads`, `GET /api/v1/media/:id`, and `GET /api/media-files/:id` (signed, on
/// `routes.root`). Files go through `app.mediaStore`, URLs through `MediaURLSigner`
/// (`MediaURLSigner(config:)`, `ref(for:)`). Uploads are checked and stripped by
/// `UploadValidation` / `JPEGSanitizer`; deleting a `media` row queues its file (trigger), and the
/// worker (S5) removes queued files and uploads left unattached for 24 hours.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum MediaModule {
    static func register(_ app: Application) throws {
        // Signed in, account exists, not suspended. Sign-up and the subscription are checked per
        // purpose: a profile photo is uploaded during sign-up itself.
        let routes = app.pilgrimRoutes.authenticated
            .grouped(AccountStateMiddleware(requiresSignup: false))
        MediaRoutes.register(routes: routes, root: app.pilgrimRoutes.root)
    }
}
