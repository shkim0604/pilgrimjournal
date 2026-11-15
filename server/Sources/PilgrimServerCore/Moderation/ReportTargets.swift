import Fluent
import Foundation
import PilgrimAPI

/// Checks that a reporter may report a target and captures its snapshot (design.md 9절 "신고").
///
/// The reporter must be a member of `groupId`, the target must belong to that group and still
/// exist (posts and comments: not expired), and it must not be the reporter or their own
/// content. Otherwise 404 (422 `CANNOT_TARGET_SELF` for one's own). Hides and blocks do not stop
/// a report — the reporter saw the content before hiding or blocking its author.
///
/// The snapshot keeps the author, title, body, prayer items, book and media IDs as they were.
/// Photo files are not copied; the console shows them while the originals exist.
enum ReportTargets {
    struct Captured: Sendable {
        var snapshot: ReportSnapshot
        /// The person the report is about (the content's author, or the reported user).
        var targetUserID: UUID?
    }

    static func capture(
        _ request: CreateReportRequest, reporter: UUID, on db: any Database, now: Date
    ) async throws -> Captured {
        let groupID = request.groupId
        guard try await ContentVisibility.membership(of: reporter, in: groupID, on: db) != nil
        else { throw APIError.notFound() }

        switch request.targetType {
        case .post:
            guard let post = try await Post.find(request.targetId, on: db),
                post.$group.id == groupID, post.expiresAt > now
            else { throw APIError.notFound() }
            try refuseSelf(post.$author.id, reporter)
            return Captured(
                snapshot: try await snapshot(of: post, on: db, now: now),
                targetUserID: post.$author.id)

        case .comment:
            guard let comment = try await Comment.find(request.targetId, on: db),
                let post = try await Post.find(comment.$post.id, on: db),
                post.$group.id == groupID, post.expiresAt > now
            else { throw APIError.notFound() }
            try refuseSelf(comment.$author.id, reporter)
            return Captured(
                snapshot: try await snapshot(of: comment, on: db, now: now),
                targetUserID: comment.$author.id)

        case .sticker:
            guard let sticker = try await Sticker.find(request.targetId, on: db),
                sticker.$group.id == groupID
            else { throw APIError.notFound() }
            try refuseSelf(sticker.$createdBy.id, reporter)
            let creator = try await User.find(sticker.$createdBy.id, on: db)
            return Captured(
                snapshot: ReportSnapshot(
                    authorId: sticker.$createdBy.id, authorName: creator?.displayName,
                    title: sticker.name, mediaIds: [sticker.$media.id], capturedAt: now),
                targetUserID: sticker.$createdBy.id)

        case .user:
            try refuseSelf(request.targetId, reporter)
            guard
                try await ContentVisibility.membership(
                    of: request.targetId, in: groupID, on: db) != nil,
                let user = try await User.find(request.targetId, on: db)
            else { throw APIError.notFound() }
            return Captured(
                snapshot: ReportSnapshot(
                    authorId: request.targetId, authorName: user.displayName,
                    mediaIds: user.$profileMedia.id.map { [$0] } ?? [], capturedAt: now),
                targetUserID: request.targetId)
        }
    }

    private static func refuseSelf(_ owner: UUID, _ reporter: UUID) throws {
        if owner == reporter { throw ModerationService.selfTarget("cannot report yourself") }
    }

    static func snapshot(of post: Post, on db: any Database, now: Date) async throws
        -> ReportSnapshot
    {
        let postID = try post.requireID()
        let author = try await User.find(post.$author.id, on: db)
        let mediaIDs = try await Media.query(on: db)
            .filter(\.$post.$id == postID)
            .sort(\.$sortOrder)
            .sort(\.$id)
            .all()
            .compactMap(\.id)
        return ReportSnapshot(
            authorId: post.$author.id, authorName: author?.displayName, title: post.title,
            body: post.body, items: post.prayerItems, book: post.book, mediaIds: mediaIDs,
            capturedAt: now)
    }

    static func snapshot(of comment: Comment, on db: any Database, now: Date) async throws
        -> ReportSnapshot
    {
        let commentID = try comment.requireID()
        let author = try await User.find(comment.$author.id, on: db)
        var mediaIDs = try await Media.query(on: db)
            .filter(\.$comment.$id == commentID)
            .sort(\.$sortOrder)
            .sort(\.$id)
            .all()
            .compactMap(\.id)
        if let stickerID = comment.$sticker.id,
            let sticker = try await Sticker.find(stickerID, on: db)
        {
            mediaIDs.append(sticker.$media.id)
        }
        return ReportSnapshot(
            authorId: comment.$author.id, authorName: author?.displayName, body: comment.body,
            mediaIds: mediaIDs, capturedAt: now)
    }
}
