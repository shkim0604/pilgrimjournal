import Vapor

/// Worker module — owned by task S5 (openspec/changes/add-private-groups/tasks.md).
///
/// The feature worker jobs not owned by another module: `expiry`, `mediaFiles`, `votes`, `appleRevocation`, `invites`, `retention`. Register each with `app.workerJobs.register(_:)`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum WorkerModule {
    static func register(_ app: Application) throws {
    }
}
