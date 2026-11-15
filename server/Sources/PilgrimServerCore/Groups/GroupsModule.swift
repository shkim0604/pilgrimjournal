import PilgrimAPI
import Vapor

/// Groups module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/api/v1/groups/**` except invites and votes: CRUD, leave, members, bans, admin transfer, seen, notification settings.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
///
/// Every route sits behind `GroupAccountGate(.member)`; non-members get 404 for every
/// `groups/:id/**` route. Path parameters: `:id` for the group, `:userId` below it.
enum GroupsModule {
    static func register(_ app: Application) throws {
        let groups = app.pilgrimRoutes.authenticated
            .grouped(GroupAccountGate(.member))
            .grouped("groups")

        groups.get { req async throws -> Response in
            let viewer = try req.userID
            return try .pilgrimJSON(
                try await GroupViews.summaries(for: viewer, config: req.pilgrimConfig, on: req.db))
        }

        groups.post { req async throws -> Response in
            let viewer = try req.userID
            let body = try req.content.decode(CreateGroupRequest.self)
            let outcome = try await GroupService.create(body, by: viewer, on: req.db)
            return try .pilgrimJSON(
                try await detail(outcome.value, req), status: outcome.status)
        }

        let group = groups.grouped(":id")

        group.get { req async throws -> Response in
            try .pilgrimJSON(try await detail(try groupID(req), req))
        }

        group.patch { req async throws -> Response in
            let id = try groupID(req)
            let body = try req.content.decode(UpdateGroupRequest.self)
            try await GroupService.rename(id, to: body.name, by: try req.userID, on: req.db)
            return try .pilgrimJSON(try await detail(id, req))
        }

        group.delete { req async throws -> Response in
            try await GroupService.scheduleDeletion(
                try groupID(req), by: try req.userID, dayLength: req.pilgrimConfig.dayLength,
                on: req.db)
            return Response(status: .noContent)
        }

        group.post("leave") { req async throws -> Response in
            try await GroupService.leave(
                try req.userID, group: try groupID(req), dayLength: req.pilgrimConfig.dayLength,
                on: req.db)
            return Response(status: .noContent)
        }

        group.get("members") { req async throws -> Response in
            let page = try await GroupService.members(
                of: try groupID(req), viewer: try req.userID,
                cursor: req.query[String.self, at: "cursor"],
                limit: req.query[Int.self, at: "limit"], config: req.pilgrimConfig, on: req.db)
            return try .pilgrimJSON(page)
        }

        group.delete("members", ":userId") { req async throws -> Response in
            try await GroupService.kick(
                try GroupAccess.uuidParameter("userId", of: req), from: try groupID(req),
                by: try req.userID, on: req.db)
            return Response(status: .noContent)
        }

        group.get("bans") { req async throws -> Response in
            try .pilgrimJSON(
                try await GroupService.bans(
                    of: try groupID(req), viewer: try req.userID, config: req.pilgrimConfig,
                    on: req.db))
        }

        group.delete("bans", ":userId") { req async throws -> Response in
            try await GroupService.unban(
                try GroupAccess.uuidParameter("userId", of: req), in: try groupID(req),
                by: try req.userID, on: req.db)
            return Response(status: .noContent)
        }

        group.post("admin", "transfer") { req async throws -> Response in
            let id = try groupID(req)
            let body = try req.content.decode(TransferAdminRequest.self)
            try await GroupService.transferAdmin(
                id, to: body.userId, by: try req.userID, on: req.db)
            return try .pilgrimJSON(try await detail(id, req))
        }

        group.post("seen") { req async throws -> Response in
            try await GroupService.markSeen(try groupID(req), by: try req.userID, on: req.db)
            return Response(status: .noContent)
        }

        group.put("notifications") { req async throws -> Response in
            let body = try req.content.decode(GroupNotificationSettings.self)
            try await GroupService.updateNotifications(
                try groupID(req), body, by: try req.userID, on: req.db)
            return Response(status: .noContent)
        }
    }

    /// The `:id` group parameter; an unparsable ID is 404.
    static func groupID(_ req: Request) throws -> UUID {
        try GroupAccess.uuidParameter("id", of: req)
    }

    static func detail(_ groupID: UUID, _ req: Request) async throws -> GroupDetail {
        try await GroupViews.detail(
            groupID, viewer: try req.userID, config: req.pilgrimConfig, on: req.db)
    }
}
