import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// `UserSummary` values with signed profile-photo URLs.
enum GroupUserSummaries {
    static func signer(_ config: AppConfig) -> MediaURLSigner {
        MediaURLSigner(secret: config.mediaURLSecret, baseURL: config.publicBaseURL)
    }

    /// Summaries for `ids` (unknown IDs are left out).
    static func load(
        _ ids: some Collection<UUID>, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> [UUID: UserSummary] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let users = try await User.query(on: db).filter(\.$id ~~ unique).all()
        let mediaIDs = users.compactMap { $0.$profileMedia.id }
        var media: [UUID: Media] = [:]
        if !mediaIDs.isEmpty {
            for row in try await Media.query(on: db).filter(\.$id ~~ mediaIDs).all() {
                if let id = row.id { media[id] = row }
            }
        }
        let signer = signer(config)
        var result: [UUID: UserSummary] = [:]
        for user in users {
            guard let id = user.id else { continue }
            let photo = user.$profileMedia.id.flatMap { media[$0] }.map {
                mediaRef($0, signer: signer, now: now)
            }
            result[id] = UserSummary(
                id: id, displayName: user.displayName ?? "", profilePhoto: photo)
        }
        return result
    }

    static func load(
        _ id: UUID?, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> UserSummary? {
        guard let id else { return nil }
        return try await load([id], config: config, on: db, now: now)[id]
    }

    static func mediaRef(_ media: Media, signer: MediaURLSigner, now: Date) -> MediaRef {
        let id = media.id ?? UUID()
        let signed = signer.signedURL(for: id, now: now)
        return MediaRef(
            id: id, width: media.width, height: media.height, byteCount: media.byteCount,
            url: signed.url, urlExpiresAt: signed.expiresAt)
    }
}

/// Builds `GroupSummary` / `GroupDetail` for one viewer (design.md "그룹·멤버·투표").
///
/// `unreadCount` is `PostUnread.counts`, the same rule as `PostResponse.isUnread`: posts by other
/// members, created after the viewer's `last_seen_at` (else their `joined_at`), that the viewer
/// may see (`ContentVisibility.visiblePost`). `latestPostAt` uses the same visibility.
enum GroupViews {
    struct Row: Sendable {
        var id: UUID
        var name: String
        var status: GroupStatus
        var adminID: UUID?
        var createdByID: UUID?
        var createdAt: Date
        var deleteAt: Date?
        var deletionReason: GroupDeletionReason?
        var notifications: GroupNotificationSettings
        var memberCount: Int
        var unreadCount: Int
        var latestPostAt: Date?
        var voteEndsAt: Date?
    }

    /// Every group `viewer` belongs to, in the order they joined.
    static func summaries(
        for viewer: UUID, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> [GroupSummary] {
        let rows = try await rows(viewer: viewer, groupID: nil, on: db, now: now)
        let users = try await GroupUserSummaries.load(
            rows.compactMap(\.adminID), config: config, on: db, now: now)
        return rows.map { summary($0, viewer: viewer, users: users) }
    }

    /// The detail of a group `viewer` belongs to, or 404.
    static func detail(
        _ groupID: UUID, viewer: UUID, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> GroupDetail {
        guard let row = try await rows(viewer: viewer, groupID: groupID, on: db, now: now).first
        else { throw APIError.notFound() }
        let users = try await GroupUserSummaries.load(
            [row.adminID, row.createdByID].compactMap { $0 }, config: config, on: db, now: now)
        let sql = try PushOutbox.sqlDatabase(db)
        let stickerCount =
            try await sql.raw(
                "SELECT count(*) AS n FROM stickers WHERE group_id = \(bind: groupID)"
            ).first()?.decode(column: "n", as: Int.self) ?? 0
        let isAdmin = row.adminID == viewer && row.status != .voting
        let activeInvites: Int? =
            isAdmin ? try await InviteService.liveInviteCount(groupID, on: db, now: now) : nil
        return GroupDetail(
            summary: summary(row, viewer: viewer, users: users),
            createdAt: row.createdAt,
            createdBy: row.createdByID.flatMap { users[$0] },
            deletionReason: row.deletionReason,
            stickerCount: stickerCount,
            activeInviteCount: activeInvites)
    }

    static func summary(_ row: Row, viewer: UUID, users: [UUID: UserSummary]) -> GroupSummary {
        GroupSummary(
            id: row.id, name: row.name, status: row.status, memberCount: row.memberCount,
            isAdmin: row.adminID == viewer && row.status != .voting,
            admin: row.status == .voting ? nil : row.adminID.flatMap { users[$0] },
            unreadCount: row.unreadCount, latestPostAt: row.latestPostAt,
            notifications: row.notifications, voteEndsAt: row.voteEndsAt,
            deleteAt: row.deleteAt)
    }

    static func rows(viewer: UUID, groupID: UUID?, on db: any Database, now: Date) async throws
        -> [Row]
    {
        let sql = try PushOutbox.sqlDatabase(db)
        let visible = ContentVisibility.visiblePost(viewer: viewer, table: "p", now: now)
        var groupFilter: SQLQueryString = ""
        if let groupID { groupFilter = "AND g.id = \(bind: groupID)" }
        let rows = try await sql.raw(
            """
            SELECT g.id, g.name, g.status, g.admin_id, g.created_by_id, g.created_at,
                   g.delete_at, g.deletion_reason,
                   m.new_post_push_enabled, m.daily_report_enabled,
                   (SELECT count(*) FROM memberships AS mc WHERE mc.group_id = g.id)
                       AS member_count,
                   (SELECT max(p.created_at) FROM posts AS p
                     WHERE p.group_id = g.id AND \(visible)) AS latest_post_at,
                   (SELECT v.ends_at FROM admin_votes AS v
                     WHERE v.group_id = g.id AND v.status = 'open' LIMIT 1) AS vote_ends_at
            FROM memberships AS m
            JOIN groups AS g ON g.id = m.group_id
            WHERE m.user_id = \(bind: viewer) \(groupFilter)
            ORDER BY m.joined_at, g.id
            """
        ).all()
        let ids = try rows.map { try $0.decode(column: "id", as: UUID.self) }
        let unread = try await PostUnread.counts(viewer: viewer, groupIDs: ids, on: db, now: now)
        return try rows.map { row in
            let statusText = try row.decode(column: "status", as: String.self)
            guard let status = GroupStatus(rawValue: statusText) else {
                throw APIError(code: .internal, message: "unknown group status \(statusText)")
            }
            let reason = try row.decode(column: "deletion_reason", as: String?.self)
            let id = try row.decode(column: "id", as: UUID.self)
            return Row(
                id: id,
                name: try row.decode(column: "name", as: String.self),
                status: status,
                adminID: try row.decode(column: "admin_id", as: UUID?.self),
                createdByID: try row.decode(column: "created_by_id", as: UUID?.self),
                createdAt: try row.decode(column: "created_at", as: Date.self),
                deleteAt: try row.decode(column: "delete_at", as: Date?.self),
                deletionReason: reason.flatMap(GroupDeletionReason.init(rawValue:)),
                notifications: GroupNotificationSettings(
                    newPostPushEnabled: try row.decode(
                        column: "new_post_push_enabled", as: Bool.self),
                    dailyReportEnabled: try row.decode(
                        column: "daily_report_enabled", as: Bool.self)),
                memberCount: try row.decode(column: "member_count", as: Int.self),
                unreadCount: unread[id] ?? 0,
                latestPostAt: try row.decode(column: "latest_post_at", as: Date?.self),
                voteEndsAt: try row.decode(column: "vote_ends_at", as: Date?.self))
        }
    }
}
