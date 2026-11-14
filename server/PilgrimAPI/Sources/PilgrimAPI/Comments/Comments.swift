import Foundation

/// `POST /posts/:id/comments` → 201 `CommentResponse`.
/// `body` ≤ 500 characters; at least one of body, media or sticker is required.
public struct CreateCommentRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    public var body: String
    /// 0–4 `comment` uploads.
    public var mediaIds: [UUID]
    /// A sticker of the same group.
    public var stickerId: UUID?

    public init(clientId: UUID, body: String, mediaIds: [UUID] = [], stickerId: UUID? = nil) {
        self.clientId = clientId
        self.body = body
        self.mediaIds = mediaIds
        self.stickerId = stickerId
    }
}

public struct CommentResponse: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var postId: UUID
    public var author: UserSummary
    public var isMine: Bool
    public var body: String
    public var media: [MediaRef]
    public var sticker: StickerResponse?
    /// The comment used a sticker that has since been deleted ("지워진 스티커").
    public var stickerRemoved: Bool
    public var createdAt: Date

    public init(
        id: UUID, postId: UUID, author: UserSummary, isMine: Bool, body: String,
        media: [MediaRef] = [], sticker: StickerResponse? = nil, stickerRemoved: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.postId = postId
        self.author = author
        self.isMine = isMine
        self.body = body
        self.media = media
        self.sticker = sticker
        self.stickerRemoved = stickerRemoved
        self.createdAt = createdAt
    }
}
