import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// Emoji and sticker reactions on posts (design.md "글·댓글·반응", "제한": up to 10 different
/// reactions per person per post). Keyed by `(post, user, key)`, so `PUT` and `DELETE` are
/// idempotent without a `clientId`.
enum ReactionRoutes {
    static func register(_ routes: any RoutesBuilder) {
        routes.put("posts", ":id", "reactions", use: add)
        routes.delete("posts", ":id", "reactions", use: remove)
    }

    /// `PUT /posts/:id/reactions` `ReactionRequest` → the post's `[ReactionSummary]`.
    @Sendable static func add(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let post = try await ContentAccess.visiblePost(req)
        let postID = try post.requireID()
        let key = try req.content.decode(ReactionRequest.self).key
        try PostRules.validate(key)
        let group = try await GroupAccess.group(post.$group.id, on: req.db)
        try GroupAccess.requireWritable(group)
        if case .sticker(let stickerID) = key {
            try await ContentAccess.requireSticker(stickerID, in: post.$group.id, on: req.db)
        }
        try await ContentAccess.consumeRateLimit(req, bucket: "reactions", rule: \.reactions)
        try await req.db.transaction { db in
            // Serialise this person's reactions on this post so the limit holds under
            // concurrent requests.
            try await ContentAccess.sql(db).raw(
                """
                SELECT pg_advisory_xact_lock(\
                hashtextextended(\(bind: "reaction|\(postID)|\(viewer)"), 0))
                """
            ).run()
            let mine = Reaction.query(on: db)
                .filter(\.$post.$id == postID)
                .filter(\.$user.$id == viewer)
            if try await matching(mine.copy(), key).first() != nil { return }
            let count = try await mine.count()
            guard count < APILimits.reactionsPerUserPerPost else {
                throw APIError.limitExceeded(
                    field: "key", limit: APILimits.reactionsPerUserPerPost,
                    "at most \(APILimits.reactionsPerUserPerPost) reactions per post")
            }
            try await Reaction(postID: postID, userID: viewer, key: key).create(on: db)
        }
        return try await summaries(postID, viewer: viewer, req)
    }

    /// `DELETE /posts/:id/reactions?emoji=` or `?stickerId=` → the post's `[ReactionSummary]`.
    /// Removing a reaction that is not there is not an error. Only the viewer's own reactions go,
    /// so membership and an unexpired post are enough (no block or hide filter).
    @Sendable static func remove(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let postID = try GroupAccess.uuidParameter("id", of: req)
        _ = try await ContentAccess.memberPost(postID, viewer: viewer, on: req.db)
        let key = try removalKey(
            emoji: req.query[String.self, at: "emoji"],
            stickerID: req.query[String.self, at: "stickerId"])
        try await matching(
            Reaction.query(on: req.db)
                .filter(\.$post.$id == postID)
                .filter(\.$user.$id == viewer),
            key
        ).delete()
        return try await summaries(postID, viewer: viewer, req)
    }

    /// The key of a `DELETE` request: exactly one of `emoji` and `stickerId`, else 400.
    static func removalKey(emoji: String?, stickerID: String?) throws -> ReactionKey {
        let emoji = emoji.flatMap { $0.isEmpty ? nil : $0 }
        let stickerID = stickerID.flatMap { $0.isEmpty ? nil : $0 }
        switch (emoji, stickerID) {
        case (let emoji?, nil):
            return .emoji(emoji)
        case (nil, let text?):
            guard let id = UUID(uuidString: text) else {
                throw APIError.invalidRequest("stickerId must be a UUID")
            }
            return .sticker(id)
        default:
            throw APIError.invalidRequest("pass exactly one of emoji and stickerId")
        }
    }

    private static func matching(_ query: QueryBuilder<Reaction>, _ key: ReactionKey)
        -> QueryBuilder<Reaction>
    {
        switch key {
        case .emoji(let emoji): query.filter(\.$emoji == emoji)
        case .sticker(let stickerID): query.filter(\.$sticker.$id == stickerID)
        }
    }

    private static func summaries(_ postID: UUID, viewer: UUID, _ req: Request) async throws
        -> Response
    {
        try .pilgrimJSON(
            try await ContentResponses(db: req.db, viewer: viewer, config: req.pilgrimConfig)
                .reactionSummaries(for: postID))
    }
}
