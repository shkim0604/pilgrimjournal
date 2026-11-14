import Foundation

/// `GET /me/daily-report?date=YYYY-MM-DD`: the 24 hours up to that day's report time.
public struct DailyReportResponse: Equatable, Sendable, Codable {
    public var date: LocalDate
    public var windowStart: Date
    public var windowEnd: Date
    /// 0 → no push was (or would be) sent.
    public var totalCount: Int
    public var groups: [DailyReportGroup]

    public init(
        date: LocalDate, windowStart: Date, windowEnd: Date, totalCount: Int,
        groups: [DailyReportGroup]
    ) {
        self.date = date
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.totalCount = totalCount
        self.groups = groups
    }
}

public struct DailyReportGroup: Equatable, Sendable, Codable {
    public var groupId: UUID
    public var groupName: String
    /// Others' posts created in the window.
    public var newPosts: [DailyReportPost]
    /// My posts with others' comments in the window (`count` = comments).
    public var commentsOnMyPosts: [DailyReportPost]
    /// My posts with others' reactions in the window (`count` = reactions).
    public var reactionsOnMyPosts: [DailyReportPost]
    /// Posts I wrote or commented on whose discussion was extended in the window.
    public var extendedPosts: [DailyReportPost]
    /// Posts disappearing within 24 hours from now that I have not hidden.
    public var expiringSoon: [DailyReportPost]

    public init(
        groupId: UUID, groupName: String, newPosts: [DailyReportPost] = [],
        commentsOnMyPosts: [DailyReportPost] = [], reactionsOnMyPosts: [DailyReportPost] = [],
        extendedPosts: [DailyReportPost] = [], expiringSoon: [DailyReportPost] = []
    ) {
        self.groupId = groupId
        self.groupName = groupName
        self.newPosts = newPosts
        self.commentsOnMyPosts = commentsOnMyPosts
        self.reactionsOnMyPosts = reactionsOnMyPosts
        self.extendedPosts = extendedPosts
        self.expiringSoon = expiringSoon
    }

    /// Entries across every section.
    public var itemCount: Int {
        newPosts.count + commentsOnMyPosts.count + reactionsOnMyPosts.count + extendedPosts.count
            + expiringSoon.count
    }
}

public struct DailyReportPost: Equatable, Sendable, Codable {
    public var postId: UUID
    public var kind: PostKind
    /// Title → book title → first item, cut to 40 characters (see `DailyReportPost.title(...)`).
    public var title: String
    public var author: UserSummary
    public var count: Int
    public var expiresAt: Date

    public init(
        postId: UUID, kind: PostKind, title: String, author: UserSummary, count: Int,
        expiresAt: Date
    ) {
        self.postId = postId
        self.kind = kind
        self.title = title
        self.author = author
        self.count = count
        self.expiresAt = expiresAt
    }

    public static let titleMaxLength = 40

    /// The report line title: the post title, else the book title, else the first prayer item
    /// (or body), cut to 40 characters.
    public static func title(
        title: String?, book: BookInfo?, items: [PrayerItem]?, body: String?
    ) -> String {
        let candidates = [title, book?.title, items?.first?.text, body]
        let text =
            candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(firstLine.prefix(titleMaxLength))
    }
}
