import Fluent
import Foundation
import PilgrimAPI

// Fluent models for design.md "Postgres 스키마 / 콘텐츠" (`Migrations/CreateContentTables.swift`).

public final class Post: Model, @unchecked Sendable {
    public static let schema = "posts"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    @Parent(key: "author_id") public var author: User
    @Enum(key: "kind") public var kind: PostKind
    @OptionalField(key: "title") public var title: String?
    @OptionalField(key: "body") public var body: String?
    /// Prayer requests only; stored as a jsonb array `[{"text","topic","who"}]`.
    @OptionalField(key: "items") public var items: JSONBArray<PrayerItem>?
    @OptionalField(key: "book_title") public var bookTitle: String?
    @OptionalField(key: "book_author") public var bookAuthor: String?
    /// `YYYY-MM-DD` (`LocalDate`), prayer requests only. See `deadlineDate`.
    @OptionalField(key: "deadline") public var deadline: String?
    @OptionalField(key: "visible_days") public var visibleDays: Int?
    /// The author's IANA time zone when posting; expiry is computed in it.
    @Field(key: "time_zone") public var timeZone: String
    @OptionalField(key: "language") public var language: String?
    /// Every read filters `expires_at > now()`; the worker deletes expired rows.
    @Field(key: "expires_at") public var expiresAt: Date
    @Field(key: "extension_count") public var extensionCount: Int
    @Field(key: "client_id") public var clientID: UUID
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    @Children(for: \.$post) public var comments: [Comment]
    @Children(for: \.$post) public var reactions: [Reaction]

    public init() {}

    public init(
        id: UUID = UUID(), groupID: UUID, authorID: UUID, kind: PostKind, timeZone: String,
        expiresAt: Date, clientID: UUID
    ) {
        self.id = id
        self.$group.id = groupID
        self.$author.id = authorID
        self.kind = kind
        self.timeZone = timeZone
        self.expiresAt = expiresAt
        self.extensionCount = 0
        self.clientID = clientID
    }

    public var deadlineDate: LocalDate? {
        get { deadline.flatMap(LocalDate.init) }
        set { deadline = newValue?.description }
    }

    public var prayerItems: [PrayerItem]? {
        get { items?.elements }
        set { items = newValue.map(JSONBArray.init) }
    }

    public var book: BookInfo? {
        guard let bookTitle else { return nil }
        return BookInfo(title: bookTitle, author: bookAuthor)
    }
}

/// One "토론 연장" (book reports only), idempotent per `(user, clientId)`.
public final class PostExtension: Model, @unchecked Sendable {
    public static let schema = "post_extensions"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "post_id") public var post: Post
    @Parent(key: "user_id") public var user: User
    @Field(key: "client_id") public var clientID: UUID
    @Field(key: "previous_expires_at") public var previousExpiresAt: Date
    @Field(key: "new_expires_at") public var newExpiresAt: Date
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), postID: UUID, userID: UUID, clientID: UUID, previousExpiresAt: Date,
        newExpiresAt: Date
    ) {
        self.id = id
        self.$post.id = postID
        self.$user.id = userID
        self.clientID = clientID
        self.previousExpiresAt = previousExpiresAt
        self.newExpiresAt = newExpiresAt
    }
}

public final class Comment: Model, @unchecked Sendable {
    public static let schema = "comments"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "post_id") public var post: Post
    @Parent(key: "author_id") public var author: User
    @Field(key: "body") public var body: String
    /// Set to nil when the sticker is deleted; `hadSticker` keeps "지워진 스티커" visible.
    @OptionalParent(key: "sticker_id") public var sticker: Sticker?
    @Field(key: "had_sticker") public var hadSticker: Bool
    @Field(key: "client_id") public var clientID: UUID
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), postID: UUID, authorID: UUID, body: String, stickerID: UUID? = nil,
        clientID: UUID
    ) {
        self.id = id
        self.$post.id = postID
        self.$author.id = authorID
        self.body = body
        self.$sticker.id = stickerID
        self.hadSticker = stickerID != nil
        self.clientID = clientID
    }
}

/// A reaction on a post: exactly one of `emoji` and `sticker`.
public final class Reaction: Model, @unchecked Sendable {
    public static let schema = "reactions"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "post_id") public var post: Post
    @Parent(key: "user_id") public var user: User
    @OptionalField(key: "emoji") public var emoji: String?
    @OptionalParent(key: "sticker_id") public var sticker: Sticker?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(id: UUID = UUID(), postID: UUID, userID: UUID, key: ReactionKey) {
        self.id = id
        self.$post.id = postID
        self.$user.id = userID
        switch key {
        case .emoji(let emoji):
            self.emoji = emoji
            self.$sticker.id = nil
        case .sticker(let stickerID):
            self.emoji = nil
            self.$sticker.id = stickerID
        }
    }

    public var key: ReactionKey? {
        if let emoji { return .emoji(emoji) }
        if let stickerID = $sticker.id { return .sticker(stickerID) }
        return nil
    }
}

public final class Sticker: Model, @unchecked Sendable {
    public static let schema = "stickers"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    @Parent(key: "created_by_id") public var createdBy: User
    @Parent(key: "media_id") public var media: Media
    @OptionalField(key: "name") public var name: String?
    @Field(key: "client_id") public var clientID: UUID
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), groupID: UUID, createdByID: UUID, mediaID: UUID, name: String? = nil,
        clientID: UUID
    ) {
        self.id = id
        self.$group.id = groupID
        self.$createdBy.id = createdByID
        self.$media.id = mediaID
        self.name = name
        self.clientID = clientID
    }
}

/// An uploaded JPEG. Unattached (`attachedAt == nil`) for up to 24 hours, then attached to one
/// post, comment, sticker or profile. Deleting the row queues the file (`media_after_delete`).
public final class Media: Model, @unchecked Sendable {
    public static let schema = "media"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "uploader_id") public var uploader: User
    @Enum(key: "purpose") public var purpose: MediaPurpose
    /// nil for profile photos.
    @OptionalParent(key: "group_id") public var group: Group?
    @OptionalParent(key: "post_id") public var post: Post?
    @OptionalParent(key: "comment_id") public var comment: Comment?
    @Field(key: "sort_order") public var sortOrder: Int
    /// Relative to `MEDIA_ROOT` (`MediaPaths.relativePath(for:)`).
    @Field(key: "file_path") public var filePath: String
    @Field(key: "content_type") public var contentType: String
    @Field(key: "byte_count") public var byteCount: Int
    @Field(key: "width") public var width: Int
    @Field(key: "height") public var height: Int
    @Field(key: "sha256") public var sha256: Data
    @Field(key: "client_id") public var clientID: UUID
    @OptionalField(key: "attached_at") public var attachedAt: Date?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), uploaderID: UUID, purpose: MediaPurpose, groupID: UUID?,
        filePath: String, byteCount: Int, width: Int, height: Int, sha256: Data, clientID: UUID
    ) {
        self.id = id
        self.$uploader.id = uploaderID
        self.purpose = purpose
        self.$group.id = groupID
        self.$post.id = nil
        self.$comment.id = nil
        self.sortOrder = 0
        self.filePath = filePath
        self.contentType = "image/jpeg"
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.sha256 = sha256
        self.clientID = clientID
    }
}

/// Files whose `media` row is gone; filled by the `media_after_delete` trigger only.
public final class MediaFileDeletion: Model, @unchecked Sendable {
    public static let schema = "media_file_deletions"

    @ID(key: .id) public var id: UUID?
    @Field(key: "file_path") public var filePath: String
    @Field(key: "attempts") public var attempts: Int
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}
}
