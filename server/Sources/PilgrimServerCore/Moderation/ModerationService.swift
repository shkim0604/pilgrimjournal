import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Blocks, hides and reports (design.md 9절) — the database side of `ModerationModule`'s
/// routes, plus the report retention purge the worker's `retention` loop calls.
///
/// Visibility itself is not decided here: `ContentVisibility` (feed, detail, comments,
/// reactions) and `PushOutbox.newPostRecipients` read `blocks` in both directions and `hides`
/// (post and person), so writing a row here is all a block or hide needs.
public enum ModerationService {
    /// Reports (with their snapshots) are deleted this long after they were filed.
    public static let reportRetention: TimeInterval = 90 * 86_400

    // MARK: - Blocks

    /// `viewer` blocks `target`. Idempotent. The target must be another user who shares a group
    /// with `viewer` (else 404, so user IDs cannot be probed), unless the block already exists.
    public static func block(_ target: UUID, by viewer: UUID, on db: any Database) async throws {
        guard target != viewer else { throw ModerationService.selfTarget("cannot block yourself") }
        if try await existingBlock(target, by: viewer, on: db) != nil { return }
        guard try await sharesGroup(viewer, target, on: db) else { throw APIError.notFound() }
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            INSERT INTO blocks (id, blocker_id, blocked_id, created_at)
            VALUES (\(bind: UUID()), \(bind: viewer), \(bind: target), now())
            ON CONFLICT (blocker_id, blocked_id) DO NOTHING
            """
        ).run()
    }

    /// Removes `viewer`'s block of `target`. Only the blocker can unblock; idempotent.
    public static func unblock(_ target: UUID, by viewer: UUID, on db: any Database) async throws {
        try await Block.query(on: db)
            .filter(\.$blocker.$id == viewer)
            .filter(\.$blocked.$id == target)
            .delete()
    }

    /// The users `viewer` blocked, newest first. Never who blocked `viewer`.
    public static func blockedUsers(of viewer: UUID, on db: any Database) async throws -> [User] {
        try await Block.query(on: db)
            .filter(\.$blocker.$id == viewer)
            .with(\.$blocked) { $0.with(\.$profileMedia) }
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()
            .map(\.blocked)
    }

    static func existingBlock(_ target: UUID, by viewer: UUID, on db: any Database)
        async throws -> Block?
    {
        try await Block.query(on: db)
            .filter(\.$blocker.$id == viewer)
            .filter(\.$blocked.$id == target)
            .first()
    }

    // MARK: - Hides

    /// `viewer` hides one post. Idempotent. The post must be one `viewer` can reach: not
    /// expired, in a group they belong to, and not their own.
    public static func hidePost(
        _ postID: UUID, by viewer: UUID, on db: any Database, now: Date = Date()
    ) async throws {
        let alreadyHidden =
            try await Hide.query(on: db)
            .filter(\.$user.$id == viewer)
            .filter(\.$post.$id == postID)
            .count() > 0
        if alreadyHidden { return }
        guard let post = try await Post.find(postID, on: db), post.expiresAt > now,
            try await ContentVisibility.membership(of: viewer, in: post.$group.id, on: db) != nil
        else { throw APIError.notFound() }
        guard post.$author.id != viewer else {
            throw ModerationService.selfTarget("cannot hide your own post")
        }
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            INSERT INTO hides (id, user_id, post_id, target_user_id, created_at)
            VALUES (\(bind: UUID()), \(bind: viewer), \(bind: postID), NULL, now())
            ON CONFLICT (user_id, post_id) WHERE post_id IS NOT NULL DO NOTHING
            """
        ).run()
    }

    public static func unhidePost(_ postID: UUID, by viewer: UUID, on db: any Database)
        async throws
    {
        try await Hide.query(on: db)
            .filter(\.$user.$id == viewer)
            .filter(\.$post.$id == postID)
            .delete()
    }

    /// `viewer` hides a person in every group. Idempotent. Same reachability rule as `block`.
    public static func hideUser(_ target: UUID, by viewer: UUID, on db: any Database)
        async throws
    {
        guard target != viewer else { throw ModerationService.selfTarget("cannot hide yourself") }
        let alreadyHidden =
            try await Hide.query(on: db)
            .filter(\.$user.$id == viewer)
            .filter(\.$targetUser.$id == target)
            .count() > 0
        if alreadyHidden { return }
        guard try await sharesGroup(viewer, target, on: db) else { throw APIError.notFound() }
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            INSERT INTO hides (id, user_id, post_id, target_user_id, created_at)
            VALUES (\(bind: UUID()), \(bind: viewer), NULL, \(bind: target), now())
            ON CONFLICT (user_id, target_user_id) WHERE target_user_id IS NOT NULL DO NOTHING
            """
        ).run()
    }

    public static func unhideUser(_ target: UUID, by viewer: UUID, on db: any Database)
        async throws
    {
        try await Hide.query(on: db)
            .filter(\.$user.$id == viewer)
            .filter(\.$targetUser.$id == target)
            .delete()
    }

    private struct HiddenPostRow: Decodable {
        var postID: UUID
        var groupID: UUID
        var groupName: String
        var title: String?
        var hiddenAt: Date

        enum CodingKeys: String, CodingKey {
            case postID = "post_id"
            case groupID = "group_id"
            case groupName = "group_name"
            case title
            case hiddenAt = "hidden_at"
        }
    }

    /// `GET /me/hides`, newest first.
    static func hides(
        of viewer: UUID, presenter: ModerationPresenter, on db: any Database
    ) async throws -> HidesResponse {
        let sql = try PushOutbox.sqlDatabase(db)
        let postRows = try await sql.raw(
            """
            SELECT h.post_id, p.group_id, g.name AS group_name, p.title, h.created_at AS hidden_at
            FROM hides AS h
            JOIN posts AS p ON p.id = h.post_id
            JOIN groups AS g ON g.id = p.group_id
            WHERE h.user_id = \(bind: viewer) AND h.post_id IS NOT NULL
            ORDER BY h.created_at DESC, h.id DESC
            """
        ).all(decoding: HiddenPostRow.self)
        let posts = postRows.map {
            HiddenPost(
                postId: $0.postID, groupId: $0.groupID, groupName: $0.groupName, title: $0.title,
                hiddenAt: $0.hiddenAt)
        }

        let userHides = try await Hide.query(on: db)
            .filter(\.$user.$id == viewer)
            .filter(\.$targetUser.$id != nil)
            .with(\.$targetUser) { $0.with(\.$profileMedia) }
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()
        var users: [HiddenUser] = []
        for hide in userHides {
            guard let target = hide.targetUser else { continue }
            users.append(
                HiddenUser(
                    user: try await presenter.userSummary(target, on: db),
                    hiddenAt: hide.createdAt ?? presenter.now))
        }
        return HidesResponse(posts: posts, users: users)
    }

    // MARK: - Reports

    /// Files a report, idempotent per `(reporter, clientId)`. The target is checked and
    /// snapshotted inside the insert's transaction (`ReportTargets.capture`).
    ///
    /// `beforeCreate` runs only when a new report will be created (the per-user rate limit), so
    /// a retried request never spends budget.
    static func fileReport(
        _ request: CreateReportRequest, by reporter: UUID, on db: any Database, now: Date = Date(),
        beforeCreate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> Idempotency.Outcome<Report> {
        let note = try validatedNote(request.note)
        let clientID = request.clientId
        let existing: @Sendable (any Database) async throws -> Report? = { db in
            try await Report.query(on: db)
                .filter(\.$reporter.$id == reporter)
                .filter(\.$clientID == clientID)
                .first()
        }
        if let found = try await existing(db) {
            return Idempotency.Outcome(value: found, created: false)
        }
        try await beforeCreate()
        return try await Idempotency.findOrCreate(on: db, existing: existing) { db in
            let captured = try await ReportTargets.capture(
                request, reporter: reporter, on: db, now: now)
            let report = Report(
                reporterID: reporter, groupID: request.groupId, targetType: request.targetType,
                targetID: request.targetId, targetUserID: captured.targetUserID,
                reason: request.reason, note: note, snapshot: captured.snapshot,
                clientID: clientID)
            try await report.create(on: db)
            return report
        }
    }

    /// Trims the note; empty becomes nil; longer than `APILimits.reportNoteMax` is 422.
    static func validatedNote(_ note: String?) throws -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        guard trimmed.count <= APILimits.reportNoteMax else {
            throw APIError.limitExceeded(field: "note", limit: APILimits.reportNoteMax)
        }
        return trimmed
    }

    /// Deletes reports (and so their snapshots) filed more than `retention` before `now`,
    /// whatever their status. Called hourly by the worker's `retention` loop (S5). Returns the
    /// number of reports deleted. `moderation_log` rows are kept (they hold no content).
    @discardableResult
    public static func purgeExpiredReportSnapshots(
        on db: any Database, now: Date = Date(), retention: TimeInterval = reportRetention
    ) async throws -> Int {
        let sql = try PushOutbox.sqlDatabase(db)
        let cutoff = now.addingTimeInterval(-retention)
        let rows = try await sql.raw(
            "DELETE FROM reports WHERE created_at < \(bind: cutoff) RETURNING id"
        ).all()
        return rows.count
    }

    // MARK: - Helpers

    /// Whether `a` and `b` are both members of at least one group.
    static func sharesGroup(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        let sql = try PushOutbox.sqlDatabase(db)
        let row = try await sql.raw(
            """
            SELECT 1 AS shared FROM memberships AS a
            JOIN memberships AS b ON b.group_id = a.group_id
            WHERE a.user_id = \(bind: a) AND b.user_id = \(bind: b)
            LIMIT 1
            """
        ).first()
        return row != nil
    }

    /// 422 `CANNOT_TARGET_SELF`.
    static func selfTarget(_ message: String) -> APIError {
        APIError(code: .cannotTargetSelf, message: message)
    }
}
