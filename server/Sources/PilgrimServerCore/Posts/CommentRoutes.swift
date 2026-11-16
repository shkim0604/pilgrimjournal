import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Comments on a post: text, up to 4 photos and/or one group sticker (design.md "글·댓글·반응",
/// 8절).
enum CommentRoutes {
    static func register(_ routes: any RoutesBuilder) {
        routes.get("posts", ":id", "comments", use: list)
        routes.post("posts", ":id", "comments", use: create)
        routes.delete("comments", ":id", use: delete)
    }

    /// `GET /posts/:id/comments?cursor&limit` → `Page<CommentResponse>`, oldest first. Comments
    /// of people blocked either way or hidden by the viewer are left out.
    @Sendable static func list(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let now = Date()
        let post = try await ContentAccess.visiblePost(req, now: now)
        let page = try PageRequest.parse(req)
        let query = Comment.query(on: req.db)
            .filter(\.$post.$id == (try post.requireID()))
            .visibleAuthors(to: viewer)
        if let cursor = page.cursor {
            query.filter(.sql(cursor.newerRows(table: Comment.schema)))
        }
        let rows = try await query.sort(\.$createdAt, .ascending).sort(\.$id, .ascending)
            .limit(page.fetchLimit).all()
        let (comments, nextCursor) = try page.split(rows) {
            ContentCursor(createdAt: $0.createdAt ?? now, id: try $0.requireID())
        }
        let responses = try await ContentResponses(
            db: req.db, viewer: viewer, config: req.pilgrimConfig, now: now
        ).comments(comments)
        return try .pilgrimJSON(Page(items: responses, nextCursor: nextCursor))
    }

    /// `POST /posts/:id/comments` `CreateCommentRequest` → 201 `CommentResponse` (200 for a
    /// repeated `clientId`, with the first comment).
    @Sendable static func create(_ req: Request) async throws -> Response {
        let viewer = try req.userID
        let post = try await ContentAccess.visiblePost(req)
        let postID = try post.requireID()
        let groupID = post.$group.id
        let request = try req.content.decode(CreateCommentRequest.self)
        let outcome = try await Idempotency.findOrCreate(
            on: req.db,
            existing: { db in
                try await Comment.query(on: db)
                    .filter(\.$author.$id == viewer)
                    .filter(\.$clientID == request.clientId)
                    .first()
            },
            create: { db in
                let group = try await GroupAccess.group(groupID, on: db)
                try GroupAccess.requireWritable(group)
                let valid = try PostRules.validate(request)
                if let stickerID = valid.stickerID {
                    try await ContentAccess.requireSticker(stickerID, in: groupID, on: db)
                }
                try await ContentAccess.consumeRateLimit(
                    req, bucket: "comments", rule: \.comments)
                let comment = Comment(
                    postID: postID, authorID: viewer, body: valid.body,
                    stickerID: valid.stickerID, clientID: request.clientId)
                try await comment.create(on: db)
                try await MediaAttachment.attach(
                    valid.mediaIDs, to: .comment(try comment.requireID()), uploader: viewer,
                    groupID: groupID, now: Date(), on: db)
                return comment
            })
        guard
            let response = try await ContentResponses(
                db: req.db, viewer: viewer, config: req.pilgrimConfig
            ).comments([outcome.value]).first
        else { throw APIError(code: .internal, message: "comment response missing") }
        return try .pilgrimJSON(response, status: outcome.status)
    }

    /// `DELETE /comments/:id` → 204. The author may always delete; the group admin may delete
    /// anyone's, except while an admin vote is open.
    @Sendable static func delete(_ req: Request) async throws -> HTTPStatus {
        let viewer = try req.userID
        let commentID = try GroupAccess.uuidParameter("id", of: req)
        // The comment must be one the viewer can see: its post visible, its author neither
        // blocked either way nor hidden.
        guard
            let comment = try await Comment.query(on: req.db)
                .filter(\.$id == commentID)
                .visibleAuthors(to: viewer)
                .first(),
            let post = try await ContentVisibility.visiblePost(
                comment.$post.id, viewer: viewer, on: req.db)
        else { throw APIError.notFound() }
        let group = try await GroupAccess.group(post.$group.id, on: req.db)
        try GroupAccess.requireCanDelete(
            authorID: comment.$author.id, viewer: viewer, group: group)
        try await comment.delete(on: req.db)
        return .noContent
    }
}
