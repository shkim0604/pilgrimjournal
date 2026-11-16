import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// Who may get a URL for a photo (`GET /media/:id`, design.md 2절 "존재를 숨긴다", 9절).
///
/// - The uploader always may (their own upload, attached or not).
/// - A post photo: when the viewer may see the post (`ContentVisibility.visiblePost`: not
///   expired, member, not hidden, not blocked).
/// - A comment photo: when the viewer may see the post and the comment's author.
/// - A sticker: any member of the sticker's group.
/// - A profile photo that is someone's current photo: anyone who shares a group with them, and
///   whoever blocked them (the blocked-users list shows the photo).
///
/// Everything else — someone else's unattached upload, another group's photo — is 404 like an
/// unknown ID.
enum MediaAccess {
    static func canView(_ media: Media, viewer: UUID, on db: any Database, now: Date = Date())
        async throws -> Bool
    {
        let mediaID = try media.requireID()
        if media.$uploader.id == viewer { return true }
        switch media.purpose {
        case .post:
            guard let postID = media.$post.id else { return false }
            return try await ContentVisibility.visiblePost(postID, viewer: viewer, on: db, now: now)
                != nil
        case .comment:
            guard let commentID = media.$comment.id,
                let comment = try await Comment.query(on: db)
                    .filter(\.$id == commentID)
                    .visibleAuthors(to: viewer)
                    .first()
            else { return false }
            return try await ContentVisibility.visiblePost(
                comment.$post.id, viewer: viewer, on: db, now: now) != nil
        case .sticker:
            guard
                let sticker = try await Sticker.query(on: db)
                    .filter(\.$media.$id == mediaID)
                    .first()
            else { return false }
            return try await ContentVisibility.membership(
                of: viewer, in: sticker.$group.id, on: db) != nil
        case .profile:
            guard
                let owner = try await User.query(on: db)
                    .filter(\.$profileMedia.$id == mediaID)
                    .first()
            else { return false }
            let ownerID = try owner.requireID()
            if try await sharesGroup(viewer, ownerID, on: db) { return true }
            return try await Block.query(on: db)
                .filter(\.$blocker.$id == viewer)
                .filter(\.$blocked.$id == ownerID)
                .count() > 0
        }
    }

    static func sharesGroup(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw APIError(code: .internal, message: "SQL database required")
        }
        return try await sql.raw(
            """
            SELECT 1 AS shared FROM memberships AS a
            JOIN memberships AS b ON b.group_id = a.group_id
            WHERE a.user_id = \(bind: a) AND b.user_id = \(bind: b)
            LIMIT 1
            """
        ).first() != nil
    }
}

/// The account checks of group photos (design.md "구독": uploads other than `profile` need the
/// subscription when it is required): the rest of `PilgrimRoutes.groupMember` — signed up and,
/// while `SUBSCRIPTION_REQUIRED` is on, entitled (`SubscriptionEntitlement`). Profile photos skip
/// them so sign-up itself can upload one. Deleted and suspended accounts are refused earlier, by
/// `AccountStateMiddleware(requiresSignup: false)`.
enum MediaAccountCheck {
    static func requireGroupMember(_ user: User, _ req: Request, now: Date = Date()) async throws {
        try user.ensureSignedUp()
        try await SubscriptionEntitlement.ensureEntitled(
            try user.requireID(), subscriptionRequired: req.pilgrimConfig.subscriptionRequired,
            on: req.db, now: now)
    }
}
