import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// The one definition of "what a viewer may see" (design.md 9절). Every read of posts, comments
/// and reactions goes through these conditions so expiry, membership, blocks and hides can never
/// drift apart between the feed, the detail view, unread counts, pushes and the Daily Report.
///
/// A post is visible to `viewer` when
/// ```
/// posts.expires_at > now
/// AND viewer is a member of posts.group_id
/// AND NOT hidden by viewer (the post, or its author)
/// AND NOT blocked in either direction between viewer and the author
/// ```
/// Comments and reactions use the author part (`authorVisible`) on their own author column.
///
/// The conditions are SQL fragments with bound parameters; `table` is the table name or alias in
/// the surrounding query (Fluent queries use the schema name, e.g. `posts`).
public enum ContentVisibility {
    /// `posts.expires_at > now`.
    public static func notExpired(table: String = Post.schema, now: Date = Date())
        -> SQLQueryString
    {
        "\(ident: table).expires_at > \(bind: now)"
    }

    /// `viewer` is a member of the row's group (`groupColumn`).
    public static func isMember(
        viewer: UUID, table: String = Post.schema, groupColumn: String = "group_id"
    ) -> SQLQueryString {
        """
        EXISTS (SELECT 1 FROM memberships AS vis_m \
        WHERE vis_m.group_id = \(ident: table).\(ident: groupColumn) \
        AND vis_m.user_id = \(bind: viewer))
        """
    }

    /// The author is neither blocked by nor blocking `viewer`, and `viewer` has not hidden them.
    public static func authorVisible(
        viewer: UUID, table: String, authorColumn: String
    ) -> SQLQueryString {
        """
        NOT EXISTS (SELECT 1 FROM blocks AS vis_b \
        WHERE (vis_b.blocker_id = \(bind: viewer) \
        AND vis_b.blocked_id = \(ident: table).\(ident: authorColumn)) \
        OR (vis_b.blocker_id = \(ident: table).\(ident: authorColumn) \
        AND vis_b.blocked_id = \(bind: viewer))) \
        AND NOT EXISTS (SELECT 1 FROM hides AS vis_hu \
        WHERE vis_hu.user_id = \(bind: viewer) \
        AND vis_hu.target_user_id = \(ident: table).\(ident: authorColumn))
        """
    }

    /// `viewer` has not hidden this post.
    public static func postNotHidden(viewer: UUID, table: String = Post.schema) -> SQLQueryString {
        """
        NOT EXISTS (SELECT 1 FROM hides AS vis_hp \
        WHERE vis_hp.user_id = \(bind: viewer) AND vis_hp.post_id = \(ident: table).id)
        """
    }

    /// The full post condition (expiry, membership, post hide, author visibility).
    public static func visiblePost(viewer: UUID, table: String = Post.schema, now: Date = Date())
        -> SQLQueryString
    {
        let parts: [SQLQueryString] = [
            notExpired(table: table, now: now),
            isMember(viewer: viewer, table: table),
            postNotHidden(viewer: viewer, table: table),
            authorVisible(viewer: viewer, table: table, authorColumn: "author_id"),
        ]
        return parts.joined(separator: " AND ")
    }

    // MARK: - Direct checks

    /// The viewer's membership in `groupID`, or nil.
    public static func membership(of viewer: UUID, in groupID: UUID, on db: any Database)
        async throws -> Membership?
    {
        try await Membership.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == viewer)
            .first()
    }

    /// The viewer's membership, or 404 `NOT_FOUND` (non-members must not learn the group exists).
    public static func requireMembership(of viewer: UUID, in groupID: UUID, on db: any Database)
        async throws -> Membership
    {
        guard let membership = try await membership(of: viewer, in: groupID, on: db) else {
            throw APIError.notFound()
        }
        return membership
    }

    /// Whether either user has blocked the other.
    public static func isBlockedEitherWay(_ a: UUID, _ b: UUID, on db: any Database)
        async throws -> Bool
    {
        try await Block.query(on: db)
            .group(.or) { either in
                either.group(.and) {
                    $0.filter(\.$blocker.$id == a).filter(\.$blocked.$id == b)
                }
                either.group(.and) {
                    $0.filter(\.$blocker.$id == b).filter(\.$blocked.$id == a)
                }
            }
            .count() > 0
    }

    /// The post if `viewer` may see it now, else nil. Callers answer 404 for nil.
    public static func visiblePost(
        _ postID: UUID, viewer: UUID, on db: any Database, now: Date = Date()
    ) async throws -> Post? {
        try await Post.query(on: db)
            .filter(\.$id == postID)
            .visible(to: viewer, now: now)
            .first()
    }
}

extension QueryBuilder where Model == Post {
    /// Restricts the query to posts `viewer` may see (`ContentVisibility.visiblePost`).
    @discardableResult
    public func visible(to viewer: UUID, now: Date = Date()) -> Self {
        filter(.sql(ContentVisibility.visiblePost(viewer: viewer, now: now)))
    }
}

extension QueryBuilder where Model == Comment {
    /// Drops comments whose author is blocked either way or hidden by `viewer`. Combine with a
    /// visible-post check for the parent post.
    @discardableResult
    public func visibleAuthors(to viewer: UUID) -> Self {
        filter(
            .sql(
                ContentVisibility.authorVisible(
                    viewer: viewer, table: Comment.schema, authorColumn: "author_id")))
    }
}

extension QueryBuilder where Model == Reaction {
    /// Drops reactions by users blocked either way or hidden by `viewer` (they also drop out of
    /// the counts).
    @discardableResult
    public func visibleAuthors(to viewer: UUID) -> Self {
        filter(
            .sql(
                ContentVisibility.authorVisible(
                    viewer: viewer, table: Reaction.schema, authorColumn: "user_id")))
    }
}
