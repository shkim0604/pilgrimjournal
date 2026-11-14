import Vapor

/// Push module — owned by task S5 (openspec/changes/add-private-groups/tasks.md).
///
/// The APNs sender (`APNSSending`) and the `pushOutbox` worker job.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum PushModule {
    static func register(_ app: Application) throws {
    }
}
