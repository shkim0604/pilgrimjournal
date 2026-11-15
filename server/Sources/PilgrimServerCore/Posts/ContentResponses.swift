import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Builds `PostResponse`, `CommentResponse` and `ReactionSummary` values for one viewer, loading
/// everything a page needs in a handful of batched queries.
///
/// Counts and summaries apply the same author filter as the feed
/// (`ContentVisibility.authorVisible`): comments and reactions of users blocked either way or
/// hidden by the viewer are left out, also from the counts (design.md 9절).
struct ContentResponses {
    let db: any Database
    let viewer: UUID
    let signer: MediaURLSigner
    let now: Date

    init(db: any Database, viewer: UUID, config: AppConfig, now: Date = Date()) {
        self.db = db
        self.viewer = viewer
        self.signer = MediaURLSigner(secret: config.mediaURLSecret, baseURL: config.publicBaseURL)
        self.now = now
    }

    // MARK: - Posts

    /// Responses in the order of `posts`. `unreadAfter` maps a group to the moment after which
    /// other people's posts are unread for the viewer (`last_seen_at`, else `joined_at`).
    func posts(_ posts: [Post], unreadAfter: [UUID: Date]) async throws -> [PostResponse] {
        guard !posts.isEmpty else { return [] }
        let postIDs = try posts.map { try $0.requireID() }
        let users = try await userSummaries(Set(posts.map { $0.$author.id }))
        let media = try await postMedia(postIDs)
        let commentCounts = try await commentCounts(postIDs)
        let reactions = try await reactionSummaries(postIDs)
        return try posts.map { post in
            let id = try post.requireID()
            let authorID = post.$author.id
            let createdAt = post.createdAt ?? now
            let isMine = authorID == viewer
            let isUnread =
                !isMine
                && unreadAfter[post.$group.id].map { createdAt > $0 } ?? false
            return PostResponse(
                id: id, groupId: post.$group.id, kind: post.kind,
                author: users[authorID] ?? Self.unknownUser(authorID), isMine: isMine,
                title: post.title, body: post.body, items: post.prayerItems, book: post.book,
                deadline: post.deadlineDate, visibleDays: post.visibleDays,
                timeZone: post.timeZone, language: post.language, createdAt: createdAt,
                expiresAt: post.expiresAt, extensionCount: post.extensionCount,
                media: media[id] ?? [], commentCount: commentCounts[id] ?? 0,
                reactions: reactions[id] ?? [], isUnread: isUnread)
        }
    }

    func post(_ post: Post, unreadAfter: Date?) async throws -> PostResponse {
        let cutoffs = unreadAfter.map { [post.$group.id: $0] } ?? [:]
        guard let response = try await posts([post], unreadAfter: cutoffs).first else {
            throw APIError(code: .internal, message: "post response missing")
        }
        return response
    }

    /// The viewer's unread cut-off in a group (`PostUnread.cutoff`).
    static func unreadAfter(_ membership: Membership) -> Date {
        PostUnread.cutoff(lastSeenAt: membership.lastSeenAt, joinedAt: membership.joinedAt)
    }

    // MARK: - Comments

    func comments(_ comments: [Comment]) async throws -> [CommentResponse] {
        guard !comments.isEmpty else { return [] }
        let commentIDs = try comments.map { try $0.requireID() }
        let stickerIDs = Set(comments.compactMap { $0.$sticker.id })
        let stickers = try await stickerResponses(stickerIDs)
        var userIDs = Set(comments.map { $0.$author.id })
        userIDs.formUnion(stickers.values.compactMap { $0.createdBy?.id })
        let users = try await userSummaries(userIDs)
        let media = try await commentMedia(commentIDs)
        return try comments.map { comment in
            let id = try comment.requireID()
            let sticker = comment.$sticker.id.flatMap { stickers[$0] }
            return CommentResponse(
                id: id, postId: comment.$post.id,
                author: users[comment.$author.id] ?? Self.unknownUser(comment.$author.id),
                isMine: comment.$author.id == viewer, body: comment.body,
                media: media[id] ?? [], sticker: sticker,
                stickerRemoved: comment.hadSticker && sticker == nil,
                createdAt: comment.createdAt ?? now)
        }
    }

    // MARK: - Reactions

    func reactionSummaries(for postID: UUID) async throws -> [ReactionSummary] {
        try await reactionSummaries([postID])[postID] ?? []
    }

    /// Per post: one summary per reaction key, in the order the key was first used.
    func reactionSummaries(_ postIDs: [UUID]) async throws -> [UUID: [ReactionSummary]] {
        guard !postIDs.isEmpty else { return [:] }
        let rows = try await ContentAccess.sql(db).raw(
            """
            SELECT r.post_id, r.emoji, r.sticker_id, count(*) AS n,
                   bool_or(r.user_id = \(bind: viewer)) AS mine, min(r.created_at) AS first_at
            FROM reactions AS r
            WHERE r.post_id = ANY(\(bind: postIDs))
              AND \(ContentVisibility.authorVisible(viewer: viewer, table: "r", authorColumn: "user_id"))
            GROUP BY r.post_id, r.emoji, r.sticker_id
            ORDER BY r.post_id, first_at, r.emoji NULLS LAST, r.sticker_id NULLS LAST
            """
        ).all()
        var result: [UUID: [ReactionSummary]] = [:]
        for row in rows {
            let postID = try row.decode(column: "post_id", as: UUID.self)
            let key: ReactionKey
            if let emoji = try row.decode(column: "emoji", as: String?.self) {
                key = .emoji(emoji)
            } else if let stickerID = try row.decode(column: "sticker_id", as: UUID?.self) {
                key = .sticker(stickerID)
            } else {
                continue
            }
            result[postID, default: []].append(
                ReactionSummary(
                    key: key, count: try row.decode(column: "n", as: Int.self),
                    reactedByMe: try row.decode(column: "mine", as: Bool.self)))
        }
        return result
    }

    // MARK: - Shared pieces

    func mediaRef(_ media: Media) throws -> MediaRef {
        let id = try media.requireID()
        let signed = signer.signedURL(for: id, now: now)
        return MediaRef(
            id: id, width: media.width, height: media.height, byteCount: media.byteCount,
            url: signed.url, urlExpiresAt: signed.expiresAt)
    }

    /// Display name and profile photo per user.
    func userSummaries(_ ids: Set<UUID>) async throws -> [UUID: UserSummary] {
        guard !ids.isEmpty else { return [:] }
        let users = try await User.query(on: db).filter(\.$id ~~ Array(ids)).all()
        let photoIDs = users.compactMap { $0.$profileMedia.id }
        var photos: [UUID: MediaRef] = [:]
        if !photoIDs.isEmpty {
            for media in try await Media.query(on: db).filter(\.$id ~~ photoIDs).all() {
                photos[try media.requireID()] = try mediaRef(media)
            }
        }
        var result: [UUID: UserSummary] = [:]
        for user in users {
            let id = try user.requireID()
            result[id] = UserSummary(
                id: id, displayName: user.displayName ?? "",
                profilePhoto: user.$profileMedia.id.flatMap { photos[$0] })
        }
        return result
    }

    static func unknownUser(_ id: UUID) -> UserSummary {
        UserSummary(id: id, displayName: "")
    }

    private func postMedia(_ postIDs: [UUID]) async throws -> [UUID: [MediaRef]] {
        let rows = try await Media.query(on: db)
            .filter(\.$post.$id ~~ postIDs.map { Optional($0) })
            .sort(\.$sortOrder).sort(\.$id)
            .all()
        var result: [UUID: [MediaRef]] = [:]
        for media in rows {
            guard let postID = media.$post.id else { continue }
            result[postID, default: []].append(try mediaRef(media))
        }
        return result
    }

    private func commentMedia(_ commentIDs: [UUID]) async throws -> [UUID: [MediaRef]] {
        let rows = try await Media.query(on: db)
            .filter(\.$comment.$id ~~ commentIDs.map { Optional($0) })
            .sort(\.$sortOrder).sort(\.$id)
            .all()
        var result: [UUID: [MediaRef]] = [:]
        for media in rows {
            guard let commentID = media.$comment.id else { continue }
            result[commentID, default: []].append(try mediaRef(media))
        }
        return result
    }

    private func commentCounts(_ postIDs: [UUID]) async throws -> [UUID: Int] {
        let rows = try await ContentAccess.sql(db).raw(
            """
            SELECT c.post_id, count(*) AS n FROM comments AS c
            WHERE c.post_id = ANY(\(bind: postIDs))
              AND \(ContentVisibility.authorVisible(viewer: viewer, table: "c", authorColumn: "author_id"))
            GROUP BY c.post_id
            """
        ).all()
        var result: [UUID: Int] = [:]
        for row in rows {
            result[try row.decode(column: "post_id", as: UUID.self)] = try row.decode(
                column: "n", as: Int.self)
        }
        return result
    }

    private func stickerResponses(_ ids: Set<UUID>) async throws -> [UUID: StickerResponse] {
        guard !ids.isEmpty else { return [:] }
        let stickers = try await Sticker.query(on: db).filter(\.$id ~~ Array(ids)).all()
        let mediaIDs = stickers.map { $0.$media.id }
        var media: [UUID: Media] = [:]
        if !mediaIDs.isEmpty {
            for row in try await Media.query(on: db).filter(\.$id ~~ mediaIDs).all() {
                media[try row.requireID()] = row
            }
        }
        let creators = try await userSummaries(Set(stickers.map { $0.$createdBy.id }))
        var result: [UUID: StickerResponse] = [:]
        for sticker in stickers {
            let id = try sticker.requireID()
            guard let stickerMedia = media[sticker.$media.id] else { continue }
            result[id] = StickerResponse(
                id: id, groupId: sticker.$group.id, name: sticker.name,
                media: try mediaRef(stickerMedia), createdBy: creators[sticker.$createdBy.id],
                createdAt: sticker.createdAt ?? now, isMine: sticker.$createdBy.id == viewer)
        }
        return result
    }
}
