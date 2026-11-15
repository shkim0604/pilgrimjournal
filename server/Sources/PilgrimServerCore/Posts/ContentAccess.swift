import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// Who may do what with posts, comments and reactions (design.md 5절 "투표 중", "유예 삭제",
/// "글·댓글·반응" 권한 열).
enum ContentAccess {
    /// New posts, comments, reactions and discussion extensions are refused while the group
    /// waits to be deleted (409 `GROUP_PENDING_DELETION`; "읽기와 스크랩만 된다"). Reading and
    /// taking one's own content down (deleting a post, comment or reaction) still work.
    static func requireWritable(_ group: Group) throws {
        if group.status == .pendingDeletion {
            throw APIError(
                code: .groupPendingDeletion, message: "the group is scheduled for deletion")
        }
    }

    /// Deleting a post or comment: its author always may; otherwise only the group's admin, and
    /// not while a new admin is being voted on (409 `ADMIN_VOTE_IN_PROGRESS`, design.md 5절).
    static func requireCanDelete(authorID: UUID, viewer: UUID, group: Group) throws {
        if authorID == viewer { return }
        if group.status == .voting {
            throw APIError(
                code: .adminVoteInProgress,
                message: "only the author can delete while an admin vote is open")
        }
        guard group.$admin.id == viewer else {
            throw APIError.forbidden("only the author or the group admin can delete this")
        }
    }

    /// The post `:id` names if the signed-in user may see it now (`ContentVisibility`), else 404 —
    /// unknown, expired, another group's, hidden and blocked posts all look the same.
    static func visiblePost(_ req: Request, now: Date = Date()) async throws -> Post {
        let postID = try uuidParameter(req, "id")
        guard
            let post = try await ContentVisibility.visiblePost(
                postID, viewer: try req.userID, on: req.db, now: now)
        else { throw APIError.notFound() }
        return post
    }

    /// The group, or 404 (it may have been deleted between the membership check and now).
    static func group(_ id: UUID, on db: any Database) async throws -> Group {
        guard let group = try await Group.find(id, on: db) else { throw APIError.notFound() }
        return group
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

    /// A required UUID path parameter; a malformed one is 404 like any unknown ID.
    static func uuidParameter(_ req: Request, _ name: String) throws -> UUID {
        guard let text = req.parameters.get(name), let id = UUID(uuidString: text) else {
            throw APIError.notFound()
        }
        return id
    }
}
