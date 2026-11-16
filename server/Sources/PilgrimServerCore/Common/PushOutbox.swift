import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Queues notifications in `push_outbox` (design.md 10절). Call inside the transaction that
/// writes the content, so a rolled-back post never notifies; the `pushOutbox` worker loop sends
/// the rows to APNs.
public enum PushOutbox {
    /// Queues the new-post push for every member of the post's group except:
    /// the author, members who turned off new-post pushes for that group, users blocked in either
    /// direction with the author, and users who hid the author (person hide).
    ///
    /// The payload carries only the group name, the author's name and IDs — never the title,
    /// body or prayer items (they must not reach the lock screen).
    /// Returns the number of rows queued.
    @discardableResult
    public static func enqueue(on db: any Database, post: Post, now: Date = Date()) async throws
        -> Int
    {
        let postID = try post.requireID()
        let groupID = post.$group.id
        let authorID = post.$author.id
        guard let group = try await Group.find(groupID, on: db) else { return 0 }
        guard let author = try await User.find(authorID, on: db) else { return 0 }
        let payload = PushPayload.newPost(
            groupID: groupID, postID: postID, kind: post.kind, groupName: group.name,
            authorName: author.displayName ?? "")
        let recipients = try await newPostRecipients(
            groupID: groupID, authorID: authorID, on: db)
        return try await enqueue(
            on: db, recipients: recipients, payload: payload, collapseID: nil, now: now)
    }

    /// Who receives the new-post push (see `enqueue(on:post:)`).
    public static func newPostRecipients(groupID: UUID, authorID: UUID, on db: any Database)
        async throws -> [UUID]
    {
        let sql = try sqlDatabase(db)
        let rows = try await sql.raw(
            """
            SELECT m.user_id FROM memberships AS m
            WHERE m.group_id = \(bind: groupID)
              AND m.user_id <> \(bind: authorID)
              AND m.new_post_push_enabled
              AND NOT EXISTS (SELECT 1 FROM blocks AS b
                  WHERE (b.blocker_id = m.user_id AND b.blocked_id = \(bind: authorID))
                     OR (b.blocker_id = \(bind: authorID) AND b.blocked_id = m.user_id))
              AND NOT EXISTS (SELECT 1 FROM hides AS h
                  WHERE h.user_id = m.user_id AND h.target_user_id = \(bind: authorID))
            ORDER BY m.joined_at, m.user_id
            """
        ).all()
        return try rows.map { try $0.decode(column: "user_id", as: UUID.self) }
    }

    /// Queues a group notice (vote started, runoff, decided, deletion scheduled) for every
    /// current member, optionally leaving some out.
    @discardableResult
    public static func enqueue(
        on db: any Database, groupEvent event: PushPayload.GroupEvent, groupID: UUID,
        excluding excluded: Set<UUID> = [], now: Date = Date()
    ) async throws -> Int {
        guard let group = try await Group.find(groupID, on: db) else { return 0 }
        let members = try await Membership.query(on: db)
            .filter(\.$group.$id == groupID)
            .all()
            .map { $0.$user.id }
            .filter { !excluded.contains($0) }
        let payload = PushPayload.group(event, groupID: groupID, groupName: group.name)
        return try await enqueue(
            on: db, recipients: members, payload: payload, collapseID: nil, now: now)
    }

    /// Queues `payload` once per recipient.
    @discardableResult
    public static func enqueue(
        on db: any Database, recipients: [UUID], payload: PushPayload, collapseID: String? = nil,
        now: Date = Date()
    ) async throws -> Int {
        guard !recipients.isEmpty else { return 0 }
        let entries = recipients.map {
            PushOutboxEntry(
                recipientID: $0, payload: payload, collapseID: collapseID, nextAttemptAt: now)
        }
        try await entries.create(on: db)
        return entries.count
    }

    static func sqlDatabase(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw APIError(code: .internal, message: "SQL database required")
        }
        return sql
    }
}
