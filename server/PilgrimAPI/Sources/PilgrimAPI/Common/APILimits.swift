import Foundation

/// Input limits (design.md "제한"). Character counts are `String.count` (grapheme clusters).
/// Violations are 422 `LIMIT_EXCEEDED` with `field` and `limit`.
public enum APILimits {
    public static let displayName = 1...30
    /// Group names: 1–40 characters, no line breaks.
    public static let groupName = 1...40
    public static let postTitleMax = 80
    public static let postBodyMax = 2_000
    /// Prayer items per post.
    public static let prayerItems = 1...10
    public static let prayerItemTextMax = 200
    public static let prayerItemWhoMax = 30
    public static let bookTitleMax = 100
    public static let bookAuthorMax = 60
    public static let commentBodyMax = 500
    /// Photos per post and per comment.
    public static let photosPerPost = 4
    public static let photosPerComment = 4
    public static let stickerNameMax = 20
    public static let stickersPerGroup = 30
    /// `CreateInviteRequest.maxUses`.
    public static let inviteMaxUses = 1...100
    public static let activeInvitesPerGroup = 20
    public static let inviteLifetimeDays = 3
    /// Live groups one user created.
    public static let createdGroupsPerUser = 20
    /// Groups one user belongs to.
    public static let joinedGroupsPerUser = 100
    /// Distinct reactions one user can put on one post.
    public static let reactionsPerUserPerPost = 10
    public static let emojiMaxUTF8Bytes = 32
    public static let reportNoteMax = 500
    /// A deadline is today … today + 365 days in the poster's time zone.
    public static let deadlineMaxDaysAhead = 365

    /// Whether `text` is a single emoji the server accepts as a reaction: one grapheme cluster,
    /// at most 32 UTF-8 bytes, and rendered as an emoji (emoji presentation, or a VS16 sequence).
    public static func isReactionEmoji(_ text: String) -> Bool {
        guard text.count == 1, text.utf8.count <= emojiMaxUTF8Bytes else { return false }
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.contains(where: { $0.properties.isEmoji })
            && scalars.contains("\u{FE0F}")
    }

    /// Whether `name` is a valid group name.
    public static func isValidGroupName(_ name: String) -> Bool {
        groupName.contains(name.count) && !name.contains(where: \.isNewline)
            && !name.allSatisfy(\.isWhitespace)
    }

    /// Whether `name` is a valid display name.
    public static func isValidDisplayName(_ name: String) -> Bool {
        displayName.contains(name.count) && !name.contains(where: \.isNewline)
            && !name.allSatisfy(\.isWhitespace)
    }
}

/// Per-user rate limits (requests per window). The server reads overrides from `RATE_LIMIT_*`.
public enum RateLimitDefaults {
    public struct Rule: Equatable, Sendable {
        public let requests: Int
        public let window: TimeInterval
    }

    public static let posts = Rule(requests: 30, window: 3_600)
    public static let comments = Rule(requests: 120, window: 3_600)
    public static let uploads = Rule(requests: 60, window: 3_600)
    public static let reactions = Rule(requests: 300, window: 3_600)
    public static let reports = Rule(requests: 20, window: 86_400)
    public static let inviteCreation = Rule(requests: 30, window: 86_400)
    public static let other = Rule(requests: 600, window: 600)
    /// Unauthenticated endpoints, per IP (`Cf-Connecting-IP`).
    public static let unauthenticatedPerIP = Rule(requests: 30, window: 600)
}
