import Foundation
import PilgrimAPI

/// The field rules of `CreatePostRequest` and `CreateCommentRequest` (design.md "글·댓글·반응",
/// "제한", 4절). Pure functions, so every rule is testable without a database.
///
/// Optional text is trimmed and an empty result counts as "not sent". Violations throw
/// `APIError`: 422 `VALIDATION_FAILED` (`field`) for a broken rule, 422 `LIMIT_EXCEEDED`
/// (`field`, `limit`) for a length or count over its limit.
enum PostRules {
    /// A create-post request that passed every rule, with the server-computed expiry.
    struct ValidatedPost: Equatable, Sendable {
        var kind: PostKind
        var title: String?
        var body: String?
        var items: [PrayerItem]?
        var book: BookInfo?
        var deadline: LocalDate?
        /// The effective lifetime of a prayer post without a deadline (default 7); nil otherwise.
        var visibleDays: Int?
        var timeZoneIdentifier: String
        var language: String?
        var mediaIDs: [UUID]
        var expiresAt: Date
    }

    /// The topic is a `PrayerRequestTopic` raw value the server does not enumerate (the app may
    /// add topics); this only bounds its size.
    static let prayerItemTopicMax = 32
    static let languages: Set<String> = ["ko", "en"]

    static func validate(_ request: CreatePostRequest, now: Date, policy: PostExpiryPolicy)
        throws -> ValidatedPost
    {
        guard let timeZone = TimeZone(identifier: request.timeZone) else {
            throw APIError.validationFailed(field: "timeZone", "unknown IANA time zone")
        }
        let language = trimmed(request.language)
        if let language, !languages.contains(language) {
            throw APIError.validationFailed(field: "language", "language must be ko or en")
        }

        let title = trimmed(request.title)
        if let title, title.count > APILimits.postTitleMax {
            throw APIError.limitExceeded(field: "title", limit: APILimits.postTitleMax)
        }

        let body = trimmed(request.body)
        switch request.kind {
        case .bookReport, .testimony:
            guard body != nil else {
                throw APIError.validationFailed(field: "body", "body is required for this kind")
            }
        case .prayer:
            break
        }
        if let body, body.count > APILimits.postBodyMax {
            throw APIError.limitExceeded(field: "body", limit: APILimits.postBodyMax)
        }

        let items: [PrayerItem]?
        switch request.kind {
        case .prayer:
            items = try validateItems(request.items)
        case .bookReport, .testimony:
            guard request.items == nil else {
                throw APIError.validationFailed(field: "items", "only prayer posts take items")
            }
            items = nil
        }

        let book: BookInfo?
        switch request.kind {
        case .bookReport:
            book = try validateBook(request.book)
        case .prayer, .testimony:
            guard request.book == nil else {
                throw APIError.validationFailed(field: "book", "only book reports take a book")
            }
            book = nil
        }

        let mediaIDs = try validateMediaIDs(request.mediaIds, limit: APILimits.photosPerPost)

        let expiresAt: Date
        do {
            expiresAt = try policy.expiresAt(
                kind: request.kind, createdAt: now, deadline: request.deadline,
                visibleDays: request.visibleDays, timeZone: timeZone)
        } catch let error as PostExpiryError {
            throw error.apiError
        }
        let visibleDays: Int? =
            request.kind == .prayer && request.deadline == nil
            ? (request.visibleDays ?? PostExpiryPolicy.defaultVisibleDays) : nil

        return ValidatedPost(
            kind: request.kind, title: title, body: body, items: items, book: book,
            deadline: request.kind == .prayer ? request.deadline : nil, visibleDays: visibleDays,
            timeZoneIdentifier: timeZone.identifier, language: language, mediaIDs: mediaIDs,
            expiresAt: expiresAt)
    }

    static func validateItems(_ items: [PrayerItem]?) throws -> [PrayerItem] {
        guard let items, !items.isEmpty else {
            throw APIError.validationFailed(field: "items", "prayer posts need 1–10 items")
        }
        guard items.count <= APILimits.prayerItems.upperBound else {
            throw APIError.limitExceeded(field: "items", limit: APILimits.prayerItems.upperBound)
        }
        return try items.map { item in
            guard let text = trimmed(item.text) else {
                throw APIError.validationFailed(field: "items", "an item has no text")
            }
            guard text.count <= APILimits.prayerItemTextMax else {
                throw APIError.limitExceeded(field: "items", limit: APILimits.prayerItemTextMax)
            }
            let who = trimmed(item.who)
            if let who, who.count > APILimits.prayerItemWhoMax {
                throw APIError.limitExceeded(field: "items", limit: APILimits.prayerItemWhoMax)
            }
            let topic = trimmed(item.topic)
            if let topic, topic.count > prayerItemTopicMax {
                throw APIError.validationFailed(field: "items", "an item topic is too long")
            }
            return PrayerItem(text: text, topic: topic, who: who)
        }
    }

    static func validateBook(_ book: BookInfo?) throws -> BookInfo {
        guard let book, let title = trimmed(book.title) else {
            throw APIError.validationFailed(field: "book", "book reports need a book title")
        }
        guard title.count <= APILimits.bookTitleMax else {
            throw APIError.limitExceeded(field: "book", limit: APILimits.bookTitleMax)
        }
        let author = trimmed(book.author)
        if let author, author.count > APILimits.bookAuthorMax {
            throw APIError.limitExceeded(field: "book", limit: APILimits.bookAuthorMax)
        }
        return BookInfo(title: title, author: author)
    }

    /// 0…`limit` distinct IDs, kept in the order sent (it is the photo order).
    static func validateMediaIDs(_ ids: [UUID], limit: Int) throws -> [UUID] {
        guard ids.count <= limit else {
            throw APIError.limitExceeded(field: "mediaIds", limit: limit)
        }
        guard Set(ids).count == ids.count else {
            throw APIError.validationFailed(field: "mediaIds", "a photo is listed twice")
        }
        return ids
    }

    // MARK: - Comments

    struct ValidatedComment: Equatable, Sendable {
        /// Trimmed; empty when the comment is only photos and/or a sticker.
        var body: String
        var mediaIDs: [UUID]
        var stickerID: UUID?
    }

    static func validate(_ request: CreateCommentRequest) throws -> ValidatedComment {
        let body = trimmed(request.body) ?? ""
        guard body.count <= APILimits.commentBodyMax else {
            throw APIError.limitExceeded(field: "body", limit: APILimits.commentBodyMax)
        }
        let mediaIDs = try validateMediaIDs(request.mediaIds, limit: APILimits.photosPerComment)
        guard !body.isEmpty || !mediaIDs.isEmpty || request.stickerId != nil else {
            throw APIError.validationFailed(
                field: "body", "a comment needs text, a photo or a sticker")
        }
        return ValidatedComment(body: body, mediaIDs: mediaIDs, stickerID: request.stickerId)
    }

    // MARK: - Reactions

    /// An emoji key must be one system emoji (`APILimits.isReactionEmoji`).
    static func validate(_ key: ReactionKey) throws {
        if case .emoji(let emoji) = key, !APILimits.isReactionEmoji(emoji) {
            throw APIError.validationFailed(field: "key", "emoji must be a single emoji")
        }
    }

    static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
