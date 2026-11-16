import PilgrimAPI
import Vapor

/// Votes module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `GET /groups/:id/vote` and `POST /groups/:id/vote/ballot`. The logic is `VoteService`, which
/// `GroupService.leave` and the worker's `votes` loop (S5) also call.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum VotesModule {
    static func register(_ app: Application) throws {
        let vote = app.pilgrimRoutes.groupMember
            .grouped("groups", ":id", "vote")

        vote.get { req async throws -> Response in
            try .pilgrimJSON(
                try await VoteService.response(
                    for: try GroupAccess.uuidParameter("id", of: req), viewer: try req.userID,
                    config: req.pilgrimConfig, on: req.db))
        }

        vote.post("ballot") { req async throws -> Response in
            let body = try req.content.decode(CastBallotRequest.self)
            return try .pilgrimJSON(
                try await VoteService.castBallot(
                    for: body.candidateUserId, in: try GroupAccess.uuidParameter("id", of: req),
                    by: try req.userID, config: req.pilgrimConfig, on: req.db))
        }
    }
}
