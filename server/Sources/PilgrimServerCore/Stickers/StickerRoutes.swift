import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Group stickers (design.md 8절, "스티커" API). Path parameters are named `id` like every other
/// `groups/:id/...` route so they never conflict in the shared router.
enum StickerRoutes {
    static func register(_ routes: any RoutesBuilder) {
        routes.get("groups", ":id", "stickers", use: list)
        routes.post("groups", ":id", "stickers", use: create)
        routes.delete("stickers", ":id", use: delete)
    }

    /// `GET /groups/:id/stickers` → `[StickerResponse]`, oldest first (members only, 404 else).
    @Sendable static func list(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let groupID = try GroupAccess.uuidParameter("id", of: req)
        _ = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: req.db)
        let stickers = try await Sticker.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .sort(\.$createdAt).sort(\.$id)
            .all()
        let responses = try await StickerPresenter(req, viewer: viewer).responses(stickers)
        return try .pilgrimJSON(responses)
    }

    /// `POST /groups/:id/stickers` `CreateStickerRequest` → 201 `StickerResponse`, 200 with the
    /// first sticker for a repeated `clientId`.
    ///
    /// The upload must be the caller's own unattached `sticker` upload for this group (409
    /// `MEDIA_NOT_ATTACHABLE`); a group holds at most 30 stickers (409 `STICKER_LIMIT_REACHED`,
    /// counted under the group row lock so two requests cannot both take the last place); none
    /// are made while the group waits to be deleted (409 `GROUP_PENDING_DELETION`). Allowed
    /// while an admin vote is open.
    @Sendable static func create(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let groupID = try GroupAccess.uuidParameter("id", of: req)
        _ = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: req.db)
        let request = try req.content.decode(CreateStickerRequest.self)
        let outcome = try await Idempotency.findOrCreate(
            on: req.db,
            existing: { db in
                try await Sticker.query(on: db)
                    .filter(\.$createdBy.$id == viewer)
                    .filter(\.$clientID == request.clientId)
                    .first()
            },
            create: { db in
                try await StickerService.create(
                    request, in: groupID, by: viewer, now: Date(), on: db)
            })
        let response = try await StickerPresenter(req, viewer: viewer).response(outcome.value)
        return try .pilgrimJSON(response, status: outcome.status)
    }

    /// `DELETE /stickers/:id` → 204. The creator always may; the group admin may too, except
    /// while an admin vote is open (409 `ADMIN_VOTE_IN_PROGRESS`); other members get 403, and
    /// non-members 404.
    @Sendable static func delete(_ req: Request) async throws -> HTTPStatus {
        let viewer = try req.userID
        let stickerID = try GroupAccess.uuidParameter("id", of: req)
        guard let sticker = try await Sticker.find(stickerID, on: req.db) else {
            throw APIError.notFound()
        }
        let (group, _) = try await GroupAccess.memberGroup(
            sticker.$group.id, viewer: viewer, on: req.db)
        try GroupAccess.requireCanDelete(
            authorID: sticker.$createdBy.id, viewer: viewer, group: group)
        try await StickerService.delete(stickerID, on: req.db)
        return .noContent
    }
}

/// `StickerResponse`s for one viewer.
struct StickerPresenter {
    let content: ContentResponses
    let signer: MediaURLSigner
    let viewer: UUID

    init(_ req: Request, viewer: UUID, now: Date = Date()) {
        self.content = ContentResponses(
            db: req.db, viewer: viewer, config: req.pilgrimConfig, now: now)
        self.signer = MediaURLSigner(config: req.pilgrimConfig)
        self.viewer = viewer
    }

    func response(_ sticker: Sticker) async throws -> StickerResponse {
        guard let response = try await responses([sticker]).first else {
            throw APIError.notFound()
        }
        return response
    }

    /// In the order of `stickers`; a sticker whose photo row is gone is left out.
    func responses(_ stickers: [Sticker]) async throws -> [StickerResponse] {
        guard !stickers.isEmpty else { return [] }
        let mediaIDs = stickers.map { $0.$media.id }
        var media: [UUID: Media] = [:]
        for row in try await Media.query(on: content.db).filter(\.$id ~~ mediaIDs).all() {
            media[try row.requireID()] = row
        }
        let creators = try await content.userSummaries(Set(stickers.map { $0.$createdBy.id }))
        return try stickers.compactMap { sticker in
            guard let photo = media[sticker.$media.id] else { return nil }
            return StickerResponse(
                id: try sticker.requireID(), groupId: sticker.$group.id, name: sticker.name,
                media: try signer.ref(for: photo, now: content.now),
                createdBy: creators[sticker.$createdBy.id],
                createdAt: sticker.createdAt ?? content.now,
                isMine: sticker.$createdBy.id == viewer)
        }
    }
}
