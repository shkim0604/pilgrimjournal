import Foundation

/// The three card kinds a group post can be.
public enum PostKind: String, Sendable, Codable, CaseIterable {
    case prayer, bookReport, testimony
}

/// One line of a prayer-request card.
public struct PrayerItem: Equatable, Hashable, Sendable, Codable {
    /// ≤ 200 characters.
    public var text: String
    /// A `PrayerRequestTopic` raw value (`health`, `family`, …).
    public var topic: String?
    /// Who it is for, ≤ 30 characters.
    public var who: String?

    public init(text: String, topic: String? = nil, who: String? = nil) {
        self.text = text
        self.topic = topic
        self.who = who
    }
}

public struct BookInfo: Equatable, Hashable, Sendable, Codable {
    /// ≤ 100 characters.
    public var title: String
    /// ≤ 60 characters.
    public var author: String?

    public init(title: String, author: String? = nil) {
        self.title = title
        self.author = author
    }
}

/// `POST /groups/:id/posts` → 201 `PostResponse`.
///
/// - `items`: prayer only, 1–10 required; any other kind sending it → 422.
/// - `book`: book report only, required.
/// - `body`: required for book reports and testimonies (1–2,000), optional for prayer (≤ 2,000).
/// - `deadline` / `visibleDays`: prayer only, never both (see `PostExpiryPolicy`).
/// - `mediaIds`: 0–4 `post` uploads.
public struct CreatePostRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    public var kind: PostKind
    public var title: String?
    public var body: String?
    public var items: [PrayerItem]?
    public var book: BookInfo?
    public var deadline: LocalDate?
    public var visibleDays: Int?
    /// The poster's IANA time zone; deadlines end in it.
    public var timeZone: String
    /// `"ko"` or `"en"`.
    public var language: String?
    public var mediaIds: [UUID]

    public init(
        clientId: UUID, kind: PostKind, title: String? = nil, body: String? = nil,
        items: [PrayerItem]? = nil, book: BookInfo? = nil, deadline: LocalDate? = nil,
        visibleDays: Int? = nil, timeZone: String, language: String? = nil, mediaIds: [UUID] = []
    ) {
        self.clientId = clientId
        self.kind = kind
        self.title = title
        self.body = body
        self.items = items
        self.book = book
        self.deadline = deadline
        self.visibleDays = visibleDays
        self.timeZone = timeZone
        self.language = language
        self.mediaIds = mediaIds
    }
}

/// A post as a member sees it. `expiresAt` is computed by the server; the app shows it as is.
public struct PostResponse: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var groupId: UUID
    public var kind: PostKind
    public var author: UserSummary
    public var isMine: Bool
    public var title: String?
    public var body: String?
    public var items: [PrayerItem]?
    public var book: BookInfo?
    public var deadline: LocalDate?
    public var visibleDays: Int?
    public var timeZone: String
    public var language: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var extensionCount: Int
    public var media: [MediaRef]
    public var commentCount: Int
    public var reactions: [ReactionSummary]
    public var isUnread: Bool

    public init(
        id: UUID, groupId: UUID, kind: PostKind, author: UserSummary, isMine: Bool,
        title: String? = nil, body: String? = nil, items: [PrayerItem]? = nil,
        book: BookInfo? = nil, deadline: LocalDate? = nil, visibleDays: Int? = nil,
        timeZone: String, language: String? = nil, createdAt: Date, expiresAt: Date,
        extensionCount: Int = 0, media: [MediaRef] = [], commentCount: Int = 0,
        reactions: [ReactionSummary] = [], isUnread: Bool = false
    ) {
        self.id = id
        self.groupId = groupId
        self.kind = kind
        self.author = author
        self.isMine = isMine
        self.title = title
        self.body = body
        self.items = items
        self.book = book
        self.deadline = deadline
        self.visibleDays = visibleDays
        self.timeZone = timeZone
        self.language = language
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.extensionCount = extensionCount
        self.media = media
        self.commentCount = commentCount
        self.reactions = reactions
        self.isUnread = isUnread
    }
}

/// `POST /posts/:id/extend` (book reports only) → `PostResponse`. Idempotent per `clientId`.
public struct ExtendPostRequest: Equatable, Sendable, Codable {
    public var clientId: UUID

    public init(clientId: UUID) {
        self.clientId = clientId
    }
}
