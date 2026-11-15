import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Unread posts (design.md "안 읽은 수", `PostResponse.isUnread`, `GroupSummary.unreadCount`).
///
/// A post is unread for a member when someone else wrote it after the member last opened the
/// group (`POST /groups/:id/seen` → `memberships.last_seen_at`), or after they joined if they
/// never have, and the member can see it (`ContentVisibility.visiblePost`: not expired, not
/// hidden, no block). The Groups module uses `counts` for `GroupSummary.unreadCount`.
public enum PostUnread {
    /// The moment after which other people's posts count as unread.
    public static func cutoff(lastSeenAt: Date?, joinedAt: Date) -> Date {
        lastSeenAt ?? joinedAt
    }

    /// Unread posts per group for `viewer`. Groups with none (or where `viewer` is not a member)
    /// are absent from the result.
    public static func counts(
        viewer: UUID, groupIDs: [UUID], on db: any Database, now: Date = Date()
    ) async throws -> [UUID: Int] {
        guard !groupIDs.isEmpty else { return [:] }
        let rows = try await ContentAccess.sql(db).raw(
            """
            SELECT posts.group_id, count(*) AS n
            FROM posts
            JOIN memberships AS um
              ON um.group_id = posts.group_id AND um.user_id = \(bind: viewer)
            WHERE posts.group_id = ANY(\(bind: groupIDs))
              AND posts.author_id <> \(bind: viewer)
              AND posts.created_at > COALESCE(um.last_seen_at, um.joined_at)
              AND \(ContentVisibility.visiblePost(viewer: viewer, table: Post.schema, now: now))
            GROUP BY posts.group_id
            """
        ).all()
        var result: [UUID: Int] = [:]
        for row in rows {
            result[try row.decode(column: "group_id", as: UUID.self)] = try row.decode(
                column: "n", as: Int.self)
        }
        return result
    }

    /// Unread posts in one group.
    public static func count(
        viewer: UUID, groupID: UUID, on db: any Database, now: Date = Date()
    ) async throws -> Int {
        try await counts(viewer: viewer, groupIDs: [groupID], on: db, now: now)[groupID] ?? 0
    }
}
