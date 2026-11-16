import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// Post-level lookups for posts, comments and reactions (design.md 9절). Group-level checks —
/// membership, writable (`pendingDeletion`), "author or admin" deletes — are `GroupAccess`.
enum ContentAccess {
    /// The post `:id` names if the signed-in user may see it now (`ContentVisibility`), else 404 —
    /// unknown, expired, another group's, hidden and blocked posts all look the same.
    static func visiblePost(_ req: Request, now: Date = Date()) async throws -> Post {
        let postID = try GroupAccess.uuidParameter("id", of: req)
        guard
            let post = try await ContentVisibility.visiblePost(
                postID, viewer: try req.userID, on: req.db, now: now)
        else { throw APIError.notFound() }
        return post
    }

    /// An unexpired post in a group the viewer belongs to, else 404 — without the block and hide
    /// filters, so people can still take down their own post, comment or reaction after the
    /// post's author blocks them or while they hide the author or the post.
    static func memberPost(_ postID: UUID, viewer: UUID, on db: any Database, now: Date = Date())
        async throws -> (post: Post, group: Group)
    {
        guard
            let post = try await Post.query(on: db)
                .filter(\.$id == postID)
                .filter(\.$expiresAt > now)
                .first()
        else { throw APIError.notFound() }
        let (group, _) = try await GroupAccess.memberGroup(post.$group.id, viewer: viewer, on: db)
        return (post, group)
    }

    /// A sticker of `groupID`, or 404: another group's sticker looks like an unknown one
    /// (design.md 8절).
    @discardableResult
    static func requireSticker(_ stickerID: UUID, in groupID: UUID, on db: any Database)
        async throws -> Sticker
    {
        guard
            let sticker = try await Sticker.query(on: db)
                .filter(\.$id == stickerID)
                .filter(\.$group.$id == groupID)
                .first()
        else { throw APIError.notFound("unknown sticker") }
        return sticker
    }

    /// Takes one token from a per-user action budget (`RateLimits`), on top of the general
    /// per-user limit every authenticated route has.
    static func consumeRateLimit(
        _ req: Request, bucket: String, rule: KeyPath<RateLimits, RateLimitRule>
    ) async throws {
        try await req.application.rateLimiter.consume(
            bucket: bucket, key: try req.userID.uuidString,
            rule: req.pilgrimConfig.rateLimits[keyPath: rule])
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw APIError(code: .internal, message: "SQL database required")
        }
        return sql
    }
}
