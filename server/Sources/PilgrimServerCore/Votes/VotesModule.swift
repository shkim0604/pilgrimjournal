import Vapor

/// Votes module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `GET /api/v1/groups/:id/vote`, `POST /groups/:id/vote/ballot`, and the vote-start helper used by leave and account deletion.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum VotesModule {
    static func register(_ app: Application) throws {
    }
}
