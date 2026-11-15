import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// The feed, creating, reading, deleting and extending posts (design.md "글·댓글·반응", 4절).
enum PostRoutes {
    static func register(_ routes: any RoutesBuilder) {
        routes.get("groups", ":id", "posts", use: feed)
        routes.post("groups", ":id", "posts", use: create)
        routes.get("posts", ":id", use: detail)
        routes.delete("posts", ":id", use: delete)
        routes.post("posts", ":id", "extend", use: extend)
    }

    /// `GET /groups/:id/posts?cursor&limit` → `Page<PostResponse>`, newest first.
    @Sendable static func feed(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let groupID = try ContentAccess.uuidParameter(req, "id")
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: req.db)
        let page = try PageRequest.parse(req)
        let now = Date()
        let query = Post.query(on: req.db)
            .filter(\.$group.$id == groupID)
            .visible(to: viewer, now: now)
        if let cursor = page.cursor {
            query.filter(.sql(cursor.olderRows(table: Post.schema)))
        }
        let rows = try await query.sort(\.$createdAt, .descending).sort(\.$id, .descending)
            .limit(page.fetchLimit).all()
        let (posts, nextCursor) = try page.split(rows) {
            ContentCursor(createdAt: $0.createdAt ?? now, id: try $0.requireID())
        }
        let responses = try await ContentResponses(
            db: req.db, viewer: viewer, config: req.pilgrimConfig, now: now
        ).posts(posts, unreadAfter: [groupID: ContentResponses.unreadAfter(membership)])
        return try .pilgrimJSON(Page(items: responses, nextCursor: nextCursor))
    }

    /// `POST /groups/:id/posts` `CreatePostRequest` → 201 `PostResponse` (200 for a repeated
    /// `clientId`, with the first post).
    @Sendable static func create(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let groupID = try ContentAccess.uuidParameter(req, "id")
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: req.db)
        let request = try req.content.decode(CreatePostRequest.self)
        let policy = PostExpiryPolicy(dayLength: req.pilgrimConfig.dayLength)
        let outcome = try await Idempotency.findOrCreate(
            on: req.db,
            existing: { db in
                try await Post.query(on: db)
                    .filter(\.$author.$id == viewer)
                    .filter(\.$clientID == request.clientId)
                    .first()
            },
            create: { db in
                let group = try await ContentAccess.group(groupID, on: db)
                try ContentAccess.requireWritable(group)
                let now = Date()
                let valid = try PostRules.validate(request, now: now, policy: policy)
                try await ContentAccess.consumeRateLimit(req, bucket: "posts", rule: \.posts)
                let post = Post(
                    groupID: groupID, authorID: viewer, kind: valid.kind,
                    timeZone: valid.timeZoneIdentifier, expiresAt: valid.expiresAt,
                    clientID: request.clientId)
                post.title = valid.title
                post.body = valid.body
                post.prayerItems = valid.items
                post.bookTitle = valid.book?.title
                post.bookAuthor = valid.book?.author
                post.deadlineDate = valid.deadline
                post.visibleDays = valid.visibleDays
                post.language = valid.language
                try await post.create(on: db)
                try await MediaAttachment.attach(
                    valid.mediaIDs, to: .post(try post.requireID()), uploader: viewer,
                    groupID: groupID, now: now, on: db)
                try await PushOutbox.enqueue(on: db, post: post, now: now)
                return post
            })
        let response = try await ContentResponses(
            db: req.db, viewer: viewer, config: req.pilgrimConfig
        ).post(outcome.value, unreadAfter: ContentResponses.unreadAfter(membership))
        return try .pilgrimJSON(response, status: outcome.status)
    }

    /// `GET /posts/:id` → `PostResponse`.
    @Sendable static func detail(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let post = try await ContentAccess.visiblePost(req)
        return try .pilgrimJSON(try await response(for: post, viewer: viewer, req))
    }

    /// `DELETE /posts/:id` → 204. The author may always take their post down; the group admin
    /// may remove anyone's post, except while an admin vote is open (design.md 5절). The row and
    /// everything under it go at once (cascade; photo files through `media_after_delete`).
    @Sendable static func delete(_ req: Request) async throws -> HTTPStatus {
        let viewer = try req.userID
        let postID = try ContentAccess.uuidParameter(req, "id")
        let now = Date()
        guard
            let post = try await Post.query(on: req.db)
                .filter(\.$id == postID)
                .filter(\.$expiresAt > now)
                .first()
        else { throw APIError.notFound() }
        _ = try await ContentVisibility.requireMembership(
            of: viewer, in: post.$group.id, on: req.db)
        if post.$author.id != viewer {
            // Someone else's post: only when the viewer can see it at all.
            guard
                try await ContentVisibility.visiblePost(
                    postID, viewer: viewer, on: req.db, now: now)
                    != nil
            else { throw APIError.notFound() }
        }
        let group = try await ContentAccess.group(post.$group.id, on: req.db)
        try ContentAccess.requireCanDelete(authorID: post.$author.id, viewer: viewer, group: group)
        try await post.delete(on: req.db)
        return .noContent
    }

    /// `POST /posts/:id/extend` `ExtendPostRequest` → `PostResponse` (201 the first time, 200 for
    /// a repeated `clientId`). Book reports only; anyone in the group, any number of times, each
    /// adding 7 days to the current `expiresAt`.
    @Sendable static func extend(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let post = try await ContentAccess.visiblePost(req)
        let postID = try post.requireID()
        let request = try req.content.decode(ExtendPostRequest.self)
        let policy = PostExpiryPolicy(dayLength: req.pilgrimConfig.dayLength)
        let outcome = try await Idempotency.findOrCreate(
            on: req.db,
            existing: { db in
                try await PostExtension.query(on: db)
                    .filter(\.$user.$id == viewer)
                    .filter(\.$clientID == request.clientId)
                    .first()?.$post.id
            },
            create: { db in
                guard post.kind == .bookReport else {
                    throw APIError(
                        code: .extendNotAllowed, message: "only book reports can be extended")
                }
                let group = try await ContentAccess.group(post.$group.id, on: db)
                try ContentAccess.requireWritable(group)
                let sql = try ContentAccess.sql(db)
                // Lock the row so concurrent extensions each add their 7 days.
                guard
                    let row = try await sql.raw(
                        """
                        SELECT expires_at FROM posts
                        WHERE id = \(bind: postID) AND expires_at > \(bind: Date())
                        FOR UPDATE
                        """
                    ).first()
                else { throw APIError.notFound() }
                let previous = try row.decode(column: "expires_at", as: Date.self)
                let extended = policy.extended(previous)
                try await sql.raw(
                    """
                    UPDATE posts SET expires_at = \(bind: extended), \
                    extension_count = extension_count + 1
                    WHERE id = \(bind: postID)
                    """
                ).run()
                try await PostExtension(
                    postID: postID, userID: viewer, clientID: request.clientId,
                    previousExpiresAt: previous, newExpiresAt: extended
                ).create(on: db)
                return postID
            })
        // Read the post again: the repeat may name an earlier extension (even of another post),
        // and the expiry changed.
        guard
            let current = try await ContentVisibility.visiblePost(
                outcome.value, viewer: viewer, on: req.db)
        else { throw APIError.notFound() }
        return try .pilgrimJSON(
            try await response(for: current, viewer: viewer, req), status: outcome.status)
    }

    /// One post as `viewer` sees it, with the unread flag of their membership.
    static func response(for post: Post, viewer: UUID, _ req: Request) async throws
        -> PostResponse
    {
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: post.$group.id, on: req.db)
        return try await ContentResponses(db: req.db, viewer: viewer, config: req.pilgrimConfig)
            .post(post, unreadAfter: ContentResponses.unreadAfter(membership))
    }
}
