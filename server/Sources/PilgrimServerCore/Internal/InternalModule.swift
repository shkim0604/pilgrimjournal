import Foundation
import PilgrimAPI
import Vapor

/// Internal module — owned by task S4 (openspec/changes/add-private-groups/tasks.md).
///
/// Operator routes on `routes.admin` (`/internal/admin/v1/*`): the `X-Admin-Token` / `Cf-Ray` guard first, then reports, deletions, suspensions, media and status.
///
/// | Route | Answer |
/// | --- | --- |
/// | `GET /reports?status=&cursor=&limit=` | `Page<AdminReport>` (newest first, with snapshots) |
/// | `GET /reports/:id` | `AdminReportDetail` (snapshot + the target as it is now) |
/// | `POST /reports/:id/resolve` | `ResolveReportRequest` → `AdminReport` |
/// | `DELETE /posts/:id?reportId=`, `/comments/:id`, `/stickers/:id` | 204 |
/// | `POST /users/:id/suspend` | `SuspendUserRequest` → 204 |
/// | `POST /users/:id/unsuspend` | 204 |
/// | `GET /media/:id` | `image/jpeg` while the original exists |
/// | `GET /status` | `AdminStatusResponse` |
///
/// Every action needs `X-Admin-Actor` and is written to `moderation_log`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum InternalModule {
    struct ReportListQuery: Content {
        var status: ReportStatus?
        var cursor: String?
        var limit: Int?
    }

    struct ReportReferenceQuery: Content {
        var reportId: UUID?
    }

    static func register(_ app: Application) throws {
        let admin = app.pilgrimRoutes.admin.grouped(AdminGuardMiddleware())

        admin.get("reports") { req async throws -> Response in
            let query = try req.query.decode(ReportListQuery.self)
            let page = try await AdminService.reports(
                status: query.status, cursor: query.cursor, limit: query.limit,
                presenter: ModerationPresenter(config: req.pilgrimConfig), on: req.db)
            return try .pilgrimJSON(page)
        }
        admin.get("reports", ":id") { req async throws -> Response in
            let detail = try await AdminService.reportDetail(
                try req.moderationID("id"),
                presenter: ModerationPresenter(config: req.pilgrimConfig), on: req.db)
            return try .pilgrimJSON(detail)
        }
        admin.post("reports", ":id", "resolve") { req async throws -> Response in
            let actor = try req.adminActor()
            let body = try req.content.decode(ResolveReportRequest.self)
            let report = try await AdminService.resolve(
                try req.moderationID("id"), body, actor: actor,
                presenter: ModerationPresenter(config: req.pilgrimConfig), on: req.db)
            return try .pilgrimJSON(report)
        }

        admin.delete("posts", ":id") { req async throws -> HTTPStatus in
            let actor = try req.adminActor()
            try await AdminService.deletePost(
                try req.moderationID("id"), reportID: try reportReference(req), actor: actor,
                on: req.db)
            return .noContent
        }
        admin.delete("comments", ":id") { req async throws -> HTTPStatus in
            let actor = try req.adminActor()
            try await AdminService.deleteComment(
                try req.moderationID("id"), reportID: try reportReference(req), actor: actor,
                on: req.db)
            return .noContent
        }
        admin.delete("stickers", ":id") { req async throws -> HTTPStatus in
            let actor = try req.adminActor()
            try await AdminService.deleteSticker(
                try req.moderationID("id"), reportID: try reportReference(req), actor: actor,
                on: req.db)
            return .noContent
        }

        admin.post("users", ":id", "suspend") { req async throws -> HTTPStatus in
            let actor = try req.adminActor()
            let body = try req.content.decode(SuspendUserRequest.self)
            try await AdminService.suspend(
                try req.moderationID("id"), body, actor: actor, on: req.db)
            return .noContent
        }
        admin.post("users", ":id", "unsuspend") { req async throws -> HTTPStatus in
            let actor = try req.adminActor()
            try await AdminService.unsuspend(try req.moderationID("id"), actor: actor, on: req.db)
            return .noContent
        }

        admin.get("media", ":id") { req async throws -> Response in
            guard let media = try await Media.find(try req.moderationID("id"), on: req.db),
                let data = try await req.mediaStore.read(media.filePath)
            else { throw APIError.notFound() }
            var headers = HTTPHeaders()
            headers.contentType = .jpeg
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }

        admin.get("status") { req async throws -> Response in
            let status = try await AdminService.status(
                registeredLoops: req.application.workerJobs.names, on: req.db)
            return try .pilgrimJSON(status)
        }
    }

    private static func reportReference(_ req: Request) throws -> UUID? {
        try req.query.decode(ReportReferenceQuery.self).reportId
    }
}
