import PilgrimAPI
import Vapor

/// Invites module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/groups/:id/invites/**` (admin) and `/invites/:code/**` (preview, accept). The logic is
/// `InviteService`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum InvitesModule {
    static func register(_ app: Application) throws {
        let authenticated = app.pilgrimRoutes.authenticated
        let member = app.pilgrimRoutes.groupMember

        let groupInvites = member.grouped("groups", ":id", "invites")

        groupInvites
            .grouped(
                RateLimitMiddleware(bucket: "inviteCreation", scope: .user) {
                    $0.rateLimits.inviteCreation
                }
            )
            .post { req async throws -> Response in
                let body = try req.content.decode(CreateInviteRequest.self)
                let outcome = try await InviteService.create(
                    body, in: try GroupAccess.uuidParameter("id", of: req), by: try req.userID,
                    config: req.pilgrimConfig, on: req.db)
                return try .pilgrimJSON(outcome.value, status: outcome.status)
            }

        groupInvites.get { req async throws -> Response in
            try .pilgrimJSON(
                try await InviteService.list(
                    try GroupAccess.uuidParameter("id", of: req), viewer: try req.userID,
                    config: req.pilgrimConfig, on: req.db))
        }

        groupInvites.delete(":code") { req async throws -> Response in
            try await InviteService.revoke(
                try code(req), in: try GroupAccess.uuidParameter("id", of: req),
                by: try req.userID, on: req.db)
            return Response(status: .noContent)
        }

        // The preview is open to signed-in users who have not finished sign-up or subscribed:
        // the join screen leads them through both. Accepting needs both.
        let signedIn = authenticated.grouped(AccountStateMiddleware(requiresSignup: false))
        signedIn.get("invites", ":code") { req async throws -> Response in
            try .pilgrimJSON(
                try await InviteService.preview(
                    try code(req), viewer: try req.userID, config: req.pilgrimConfig, on: req.db))
        }

        member.post("invites", ":code", "accept") { req async throws -> Response in
            try .pilgrimJSON(
                try await InviteService.accept(
                    try code(req), by: try req.userID, config: req.pilgrimConfig, on: req.db))
        }
    }

    static func code(_ req: Request) throws -> String {
        guard let code = req.parameters.get("code") else { throw APIError.notFound() }
        return code
    }
}
