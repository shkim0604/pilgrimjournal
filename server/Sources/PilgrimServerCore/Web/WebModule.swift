import Vapor

/// Web module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/.well-known/apple-app-site-association` and the `/i/:code` page, on `routes.root`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum WebModule {
    static func register(_ app: Application) throws {
    }
}
