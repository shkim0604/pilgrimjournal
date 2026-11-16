import Foundation
import PilgrimAPI
import Vapor

/// Moderation module — owned by task S4 (openspec/changes/add-private-groups/tasks.md).
///
/// Blocks, hides (`/api/v1/me/blocks`, `me/hides`), `POST /reports` with snapshots and the report webhook.
///
/// | Route | Answer |
/// | --- | --- |
/// | `GET /me/blocks` | `[UserSummary]` (whom I blocked) |
/// | `PUT /me/blocks/:userId`, `DELETE` | 204 |
/// | `GET /me/hides` | `HidesResponse` |
/// | `PUT /me/hides/posts/:postId`, `DELETE` | 204 |
/// | `PUT /me/hides/users/:userId`, `DELETE` | 204 |
/// | `POST /reports` | 201 `ReportReceipt` (200 for a repeated `clientId`) |
///
/// Every route sits behind `PilgrimRoutes.signedUp` (suspended → 403 `ACCOUNT_SUSPENDED`, no name
/// → 403 `SIGNUP_REQUIRED`). Blocking or hiding a person needs a shared group; hiding a post or
/// reporting needs membership in its group (else 404). Self-targets are 422 `CANNOT_TARGET_SELF`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum ModerationModule {
    static func register(_ app: Application) throws {
        let routes = app.pilgrimRoutes.signedUp
        let me = routes.grouped("me")

        me.get("blocks") { req async throws -> Response in
            let users = try await ModerationService.blockedUsers(of: try req.userID, on: req.db)
            let presenter = ModerationPresenter(config: req.pilgrimConfig)
            var summaries: [UserSummary] = []
            for user in users {
                summaries.append(try await presenter.userSummary(user, on: req.db))
            }
            return try .pilgrimJSON(summaries)
        }
        me.put("blocks", ":userId") { req async throws -> HTTPStatus in
            try await ModerationService.block(
                try req.moderationID("userId"), by: try req.userID, on: req.db)
            return .noContent
        }
        me.delete("blocks", ":userId") { req async throws -> HTTPStatus in
            try await ModerationService.unblock(
                try req.moderationID("userId"), by: try req.userID, on: req.db)
            return .noContent
        }

        me.get("hides") { req async throws -> Response in
            let hides = try await ModerationService.hides(
                of: try req.userID, presenter: ModerationPresenter(config: req.pilgrimConfig),
                on: req.db)
            return try .pilgrimJSON(hides)
        }
        me.put("hides", "posts", ":postId") { req async throws -> HTTPStatus in
            try await ModerationService.hidePost(
                try req.moderationID("postId"), by: try req.userID, on: req.db)
            return .noContent
        }
        me.delete("hides", "posts", ":postId") { req async throws -> HTTPStatus in
            try await ModerationService.unhidePost(
                try req.moderationID("postId"), by: try req.userID, on: req.db)
            return .noContent
        }
        me.put("hides", "users", ":userId") { req async throws -> HTTPStatus in
            try await ModerationService.hideUser(
                try req.moderationID("userId"), by: try req.userID, on: req.db)
            return .noContent
        }
        me.delete("hides", "users", ":userId") { req async throws -> HTTPStatus in
            try await ModerationService.unhideUser(
                try req.moderationID("userId"), by: try req.userID, on: req.db)
            return .noContent
        }

        routes.post("reports") { req async throws -> Response in
            let body = try req.content.decode(CreateReportRequest.self)
            let reporter = try req.userID
            let application = req.application
            let rule = req.pilgrimConfig.rateLimits.reports
            let outcome = try await ModerationService.fileReport(
                body, by: reporter, on: req.db,
                beforeCreate: {
                    try await application.rateLimiter.consume(
                        bucket: "reports", key: reporter.uuidString, rule: rule)
                })
            let report = outcome.value
            if outcome.created {
                application.reportNotifier.reportFiled(
                    ReportWebhookSummary(reason: report.reason, targetType: report.targetType),
                    app: application)
            }
            return try .pilgrimJSON(
                ReportReceipt(id: try report.requireID(), createdAt: report.createdAt ?? Date()),
                status: outcome.status)
        }
    }
}

extension Request {
    /// A UUID path parameter, or 404 `NOT_FOUND` when it is missing or malformed.
    func moderationID(_ name: String) throws -> UUID {
        guard let value = parameters.get(name, as: UUID.self) else { throw APIError.notFound() }
        return value
    }
}
