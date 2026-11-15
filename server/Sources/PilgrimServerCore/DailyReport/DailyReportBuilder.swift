import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Builds one user's `DailyReportResponse` (design.md 11절). The push and
/// `GET /me/daily-report` share it, so the screen shows exactly what the push counted.
///
/// Per group the user belongs to — except groups whose Daily Report they turned off
/// (`memberships.daily_report_enabled`) — with `ContentVisibility` applied to every post
/// (expiry, post and person hides, blocks either way) and to every comment and reaction author:
///
/// - `newPosts`: others' posts created in the window (`count` 1)
/// - `commentsOnMyPosts`: my posts with others' comments in the window (`count` = comments)
/// - `reactionsOnMyPosts`: my posts with others' reactions in the window (`count` = reactions)
/// - `extendedPosts`: posts I wrote or commented on that someone else extended in the window
///   (`count` = extensions)
/// - `expiringSoon`: posts disappearing within one day (`TIME_SCALE_DAY_SECONDS`) of `now`
///   (`count` 1)
///
/// Groups with nothing to report are left out; `totalCount` is the number of entries across all
/// sections (`DailyReportGroup.itemCount`), so 0 means there is nothing to send.
public struct DailyReportBuilder: Sendable {
    public let db: any Database
    public let config: AppConfig

    public init(db: any Database, config: AppConfig) {
        self.db = db
        self.config = config
    }

    enum Section: CaseIterable {
        case newPosts, commentsOnMyPosts, reactionsOnMyPosts, extendedPosts, expiringSoon
    }

    struct Line {
        var section: Section
        var groupID: UUID
        var postID: UUID
        var authorID: UUID
        var kind: PostKind
        var title: String
        var count: Int
        var expiresAt: Date
    }

    /// The report for `date` in the user's zone and report time.
    public func report(
        for userID: UUID, date: LocalDate, minute: Int, timeZone: TimeZone, now: Date = Date()
    ) async throws -> DailyReportResponse {
        let window = DailyReportSchedule.window(on: date, minute: minute, in: timeZone)
        return try await report(for: userID, date: date, window: window, now: now)
    }

    /// The report over `window`, labelled `date`.
    public func report(
        for userID: UUID, date: LocalDate, window: DateInterval, now: Date = Date()
    ) async throws -> DailyReportResponse {
        let groups = try await reportGroups(of: userID)
        guard !groups.isEmpty else {
            return DailyReportResponse(
                date: date, windowStart: window.start, windowEnd: window.end, totalCount: 0,
                groups: [])
        }
        var lines: [Line] = []
        for section in Section.allCases {
            lines += try await self.lines(section, viewer: userID, window: window, now: now)
        }
        let authors = try await GroupUserSummaries.load(
            Set(lines.map(\.authorID)), config: config, on: db, now: now)
        var byGroup: [UUID: DailyReportGroup] = [:]
        for line in lines {
            guard let name = groups.first(where: { $0.id == line.groupID })?.name else { continue }
            var group =
                byGroup[line.groupID] ?? DailyReportGroup(groupId: line.groupID, groupName: name)
            let post = DailyReportPost(
                postId: line.postID, kind: line.kind, title: line.title,
                author: authors[line.authorID] ?? ContentResponses.unknownUser(line.authorID),
                count: line.count, expiresAt: line.expiresAt)
            switch line.section {
            case .newPosts: group.newPosts.append(post)
            case .commentsOnMyPosts: group.commentsOnMyPosts.append(post)
            case .reactionsOnMyPosts: group.reactionsOnMyPosts.append(post)
            case .extendedPosts: group.extendedPosts.append(post)
            case .expiringSoon: group.expiringSoon.append(post)
            }
            byGroup[line.groupID] = group
        }
        let ordered = groups.compactMap { byGroup[$0.id] }.filter { $0.itemCount > 0 }
        return DailyReportResponse(
            date: date, windowStart: window.start, windowEnd: window.end,
            totalCount: ordered.reduce(0) { $0 + $1.itemCount }, groups: ordered)
    }

    // MARK: - Queries

    /// The groups whose Daily Report the user keeps on, in the order they joined.
    func reportGroups(of userID: UUID) async throws -> [(id: UUID, name: String)] {
        let rows = try await sql.raw(
            """
            SELECT g.id, g.name FROM memberships AS m
            JOIN groups AS g ON g.id = m.group_id
            WHERE m.user_id = \(bind: userID) AND m.daily_report_enabled
            ORDER BY m.joined_at, g.id
            """
        ).all()
        return try rows.map {
            (
                try $0.decode(column: "id", as: UUID.self),
                try $0.decode(column: "name", as: String.self)
            )
        }
    }

    func lines(_ section: Section, viewer: UUID, window: DateInterval, now: Date) async throws
        -> [Line]
    {
        let rows = try await sql.raw(query(section, viewer: viewer, window: window, now: now)).all()
        return try rows.map { row in
            let kindRaw = try row.decode(column: "kind", as: String.self)
            guard let kind = PostKind(rawValue: kindRaw) else {
                throw APIError(code: .internal, message: "unknown post kind \(kindRaw)")
            }
            let bookTitle = try row.decode(column: "book_title", as: String?.self)
            let firstItem = try row.decode(column: "first_item", as: String?.self)
            let title = DailyReportPost.title(
                title: try row.decode(column: "title", as: String?.self),
                book: bookTitle.map { BookInfo(title: $0) },
                items: firstItem.map { [PrayerItem(text: $0)] },
                body: try row.decode(column: "body", as: String?.self))
            return Line(
                section: section,
                groupID: try row.decode(column: "group_id", as: UUID.self),
                postID: try row.decode(column: "post_id", as: UUID.self),
                authorID: try row.decode(column: "author_id", as: UUID.self),
                kind: kind, title: title,
                count: try row.decode(column: "item_count", as: Int.self),
                expiresAt: try row.decode(column: "expires_at", as: Date.self))
        }
    }

    /// One section's rows: the post columns plus `item_count`.
    func query(_ section: Section, viewer: UUID, window: DateInterval, now: Date)
        -> SQLQueryString
    {
        let columns: SQLQueryString = """
            p.id AS post_id, p.group_id, p.author_id, p.kind, p.title, p.body, p.book_title, \
            p.items->0->>'text' AS first_item, p.expires_at
            """
        // Only groups whose report the viewer keeps on, and only posts the viewer may see.
        let scope: SQLQueryString = """
            FROM posts AS p
            JOIN memberships AS dr_m ON dr_m.group_id = p.group_id \
            AND dr_m.user_id = \(bind: viewer) AND dr_m.daily_report_enabled
            """
        let visible = ContentVisibility.visiblePost(viewer: viewer, table: "p", now: now)
        let start = window.start
        let end = window.end
        switch section {
        case .newPosts:
            return """
                SELECT \(columns), 1 AS item_count \(scope)
                WHERE \(visible) AND p.author_id <> \(bind: viewer)
                  AND p.created_at >= \(bind: start) AND p.created_at < \(bind: end)
                ORDER BY p.created_at, p.id
                """
        case .commentsOnMyPosts:
            return """
                SELECT \(columns), COUNT(c.id)::int AS item_count \(scope)
                JOIN comments AS c ON c.post_id = p.id
                WHERE \(visible) AND p.author_id = \(bind: viewer)
                  AND c.author_id <> \(bind: viewer)
                  AND c.created_at >= \(bind: start) AND c.created_at < \(bind: end)
                  AND \(ContentVisibility.authorVisible(viewer: viewer, table: "c", authorColumn: "author_id"))
                GROUP BY p.id
                ORDER BY p.created_at, p.id
                """
        case .reactionsOnMyPosts:
            return """
                SELECT \(columns), COUNT(r.id)::int AS item_count \(scope)
                JOIN reactions AS r ON r.post_id = p.id
                WHERE \(visible) AND p.author_id = \(bind: viewer)
                  AND r.user_id <> \(bind: viewer)
                  AND r.created_at >= \(bind: start) AND r.created_at < \(bind: end)
                  AND \(ContentVisibility.authorVisible(viewer: viewer, table: "r", authorColumn: "user_id"))
                GROUP BY p.id
                ORDER BY p.created_at, p.id
                """
        case .extendedPosts:
            return """
                SELECT \(columns), COUNT(e.id)::int AS item_count \(scope)
                JOIN post_extensions AS e ON e.post_id = p.id
                WHERE \(visible) AND e.user_id <> \(bind: viewer)
                  AND e.created_at >= \(bind: start) AND e.created_at < \(bind: end)
                  AND (p.author_id = \(bind: viewer) OR EXISTS (SELECT 1 FROM comments AS mc \
                  WHERE mc.post_id = p.id AND mc.author_id = \(bind: viewer)))
                GROUP BY p.id
                ORDER BY p.created_at, p.id
                """
        case .expiringSoon:
            let horizon = now + config.dayLength
            return """
                SELECT \(columns), 1 AS item_count \(scope)
                WHERE \(visible) AND p.expires_at <= \(bind: horizon)
                ORDER BY p.expires_at, p.id
                """
        }
    }

    private var sql: any SQLDatabase {
        get throws { try PushOutbox.sqlDatabase(db) }
    }
}
