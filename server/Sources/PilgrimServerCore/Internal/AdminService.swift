import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// The operator actions behind `/internal/admin/v1/*` (design.md 14절). Every change writes a
/// `moderation_log` row (actor, action, target, report ID, operator note — never content) in the
/// same transaction.
enum AdminService {
    static let noteMax = 500

    // MARK: - Reports

    /// Newest first. `cursor` is the last report ID of the previous page.
    static func reports(
        status: ReportStatus?, cursor: String?, limit requested: Int?,
        presenter: ModerationPresenter, on db: any Database
    ) async throws -> PilgrimAPI.Page<AdminReport> {
        let limit = min(
            max(requested ?? PilgrimAPI.Page<AdminReport>.defaultLimit, 1),
            PilgrimAPI.Page<AdminReport>.maximumLimit)
        let query = Report.query(on: db)
            .with(\.$reporter)
            .with(\.$targetUser)
            .with(\.$group)
        if let status {
            query.filter(\.$status == status)
        }
        if let cursor {
            guard let cursorID = UUID(uuidString: cursor) else {
                throw APIError.invalidRequest("invalid cursor")
            }
            let after: SQLQueryString = """
                (reports.created_at, reports.id) < \
                (SELECT c.created_at, c.id FROM reports AS c WHERE c.id = \(bind: cursorID))
                """
            query.filter(.sql(after))
        }
        let rows =
            try await query
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .limit(limit + 1)
            .all()
        let page = Array(rows.prefix(limit))
        let items = try page.map { try adminReport($0, presenter: presenter) }
        let next = rows.count > limit ? try page.last?.requireID().uuidString.lowercased() : nil
        return PilgrimAPI.Page(items: items, nextCursor: next)
    }

    static func reportDetail(
        _ id: UUID, presenter: ModerationPresenter, on db: any Database
    ) async throws -> AdminReportDetail {
        let report = try await loadReport(id, on: db)
        return AdminReportDetail(
            report: try adminReport(report, presenter: presenter),
            liveTarget: try await liveTarget(of: report, presenter: presenter, on: db))
    }

    static func resolve(
        _ id: UUID, _ request: ResolveReportRequest, actor: String,
        presenter: ModerationPresenter, on db: any Database
    ) async throws -> AdminReport {
        let note = try validatedNote(request.note)
        try await db.transaction { tx in
            guard let report = try await Report.find(id, on: tx) else { throw APIError.notFound() }
            report.status = request.resolution == .dismissed ? .dismissed : .actioned
            report.resolvedAt = presenter.now
            report.resolvedBy = actor
            try await report.update(on: tx)
            try await log(
                .resolveReport, target: "report", id: id, reportID: id, actor: actor, note: note,
                on: tx)
        }
        return try adminReport(try await loadReport(id, on: db), presenter: presenter)
    }

    private static func loadReport(_ id: UUID, on db: any Database) async throws -> Report {
        guard
            let report = try await Report.query(on: db)
                .filter(\.$id == id)
                .with(\.$reporter)
                .with(\.$targetUser)
                .with(\.$group)
                .first()
        else { throw APIError.notFound() }
        return report
    }

    /// `report` must have `reporter`, `targetUser` and `group` eager-loaded.
    static func adminReport(_ report: Report, presenter: ModerationPresenter) throws -> AdminReport
    {
        AdminReport(
            id: try report.requireID(), createdAt: report.createdAt ?? presenter.now,
            status: report.status, reason: report.reason, note: report.note,
            targetType: report.targetType, targetId: report.targetID, groupId: report.$group.id,
            groupName: report.group?.name,
            reporter: try report.reporter.map(presenter.adminUserRef),
            targetUser: try report.targetUser.map(presenter.adminUserRef),
            snapshot: report.snapshot, resolvedAt: report.resolvedAt, resolvedBy: report.resolvedBy
        )
    }

    // MARK: - Live target

    static func liveTarget(
        of report: Report, presenter: ModerationPresenter, on db: any Database
    ) async throws -> AdminTarget {
        switch report.targetType {
        case .post:
            guard let post = try await Post.find(report.targetID, on: db) else {
                return AdminTarget(exists: false)
            }
            return AdminTarget(
                exists: true, post: try await postResponse(post, presenter: presenter, on: db))
        case .comment:
            guard let comment = try await Comment.find(report.targetID, on: db) else {
                return AdminTarget(exists: false)
            }
            return AdminTarget(
                exists: true,
                comment: try await commentResponse(comment, presenter: presenter, on: db))
        case .sticker:
            guard let sticker = try await Sticker.find(report.targetID, on: db),
                let response = try await presenter.sticker(sticker, on: db)
            else { return AdminTarget(exists: false) }
            return AdminTarget(exists: true, sticker: response)
        case .user:
            return AdminTarget(exists: try await User.find(report.targetID, on: db) != nil)
        }
    }

    private static func summary(
        of userID: UUID, presenter: ModerationPresenter, on db: any Database
    )
        async throws -> UserSummary
    {
        guard let user = try await User.find(userID, on: db) else {
            return UserSummary(id: userID, displayName: "")
        }
        return try await presenter.userSummary(user, on: db)
    }

    /// The post as an operator sees it: every reaction counted, nothing filtered.
    static func postResponse(_ post: Post, presenter: ModerationPresenter, on db: any Database)
        async throws -> PostResponse
    {
        let postID = try post.requireID()
        let media = try await Media.query(on: db)
            .filter(\.$post.$id == postID)
            .sort(\.$sortOrder)
            .sort(\.$id)
            .all()
        let reactions = try await Reaction.query(on: db)
            .filter(\.$post.$id == postID)
            .sort(\.$createdAt)
            .sort(\.$id)
            .all()
        var counts: [ReactionKey: Int] = [:]
        var order: [ReactionKey] = []
        for reaction in reactions {
            guard let key = reaction.key else { continue }
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return PostResponse(
            id: postID, groupId: post.$group.id, kind: post.kind,
            author: try await summary(of: post.$author.id, presenter: presenter, on: db),
            isMine: false, title: post.title, body: post.body, items: post.prayerItems,
            book: post.book, deadline: post.deadlineDate, visibleDays: post.visibleDays,
            timeZone: post.timeZone, language: post.language,
            createdAt: post.createdAt ?? presenter.now, expiresAt: post.expiresAt,
            extensionCount: post.extensionCount, media: try media.map(presenter.mediaRef),
            commentCount: try await Comment.query(on: db).filter(\.$post.$id == postID).count(),
            reactions: order.map {
                ReactionSummary(key: $0, count: counts[$0] ?? 0, reactedByMe: false)
            })
    }

    static func commentResponse(
        _ comment: Comment, presenter: ModerationPresenter, on db: any Database
    ) async throws -> CommentResponse {
        let commentID = try comment.requireID()
        let media = try await Media.query(on: db)
            .filter(\.$comment.$id == commentID)
            .sort(\.$sortOrder)
            .sort(\.$id)
            .all()
        var sticker: StickerResponse?
        if let stickerID = comment.$sticker.id, let row = try await Sticker.find(stickerID, on: db)
        {
            sticker = try await presenter.sticker(row, on: db)
        }
        return CommentResponse(
            id: commentID, postId: comment.$post.id,
            author: try await summary(of: comment.$author.id, presenter: presenter, on: db),
            isMine: false, body: comment.body, media: try media.map(presenter.mediaRef),
            sticker: sticker, stickerRemoved: comment.hadSticker && sticker == nil,
            createdAt: comment.createdAt ?? presenter.now)
    }

    // MARK: - Deletions

    /// Hard delete. Comments, reactions, extensions, hides and photo rows cascade; the
    /// `media_after_delete` trigger queues every photo file for the worker.
    static func deletePost(
        _ id: UUID, reportID: UUID?, actor: String, on db: any Database
    ) async throws {
        try await db.transaction { tx in
            guard let post = try await Post.find(id, on: tx) else { throw APIError.notFound() }
            try await post.delete(on: tx)
            try await log(
                .deletePost, target: "post", id: id, reportID: reportID, actor: actor, on: tx)
        }
    }

    /// Hard delete; the comment's photos cascade (and their files are queued).
    static func deleteComment(
        _ id: UUID, reportID: UUID?, actor: String, on db: any Database
    ) async throws {
        try await db.transaction { tx in
            guard let comment = try await Comment.find(id, on: tx) else {
                throw APIError.notFound()
            }
            try await comment.delete(on: tx)
            try await log(
                .deleteComment, target: "comment", id: id, reportID: reportID, actor: actor, on: tx)
        }
    }

    /// Deletes the sticker's media row, which cascades to the sticker and its reactions; comments
    /// that used it keep `had_sticker` and show "지워진 스티커". The file is queued by the trigger.
    static func deleteSticker(
        _ id: UUID, reportID: UUID?, actor: String, on db: any Database
    ) async throws {
        try await db.transaction { tx in
            guard let sticker = try await Sticker.find(id, on: tx) else {
                throw APIError.notFound()
            }
            let mediaID = sticker.$media.id
            try await sticker.delete(on: tx)
            try await Media.query(on: tx).filter(\.$id == mediaID).delete()
            try await log(
                .deleteSticker, target: "sticker", id: id, reportID: reportID, actor: actor, on: tx)
        }
    }

    // MARK: - Suspension

    /// Sets `users.suspended_at` (and `suspended_until`, nil = indefinite). The auth layer (S1)
    /// answers 403 `ACCOUNT_SUSPENDED` while `User.isSuspended(at:)` is true. Content stays;
    /// the operator deletes it separately.
    static func suspend(
        _ userID: UUID, _ request: SuspendUserRequest, actor: String, on db: any Database,
        now: Date = Date()
    ) async throws {
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else {
            throw APIError.validationFailed(field: "reason", "reason is required")
        }
        guard reason.count <= noteMax else {
            throw APIError.limitExceeded(field: "reason", limit: noteMax)
        }
        if let until = request.until, until <= now {
            throw APIError.validationFailed(field: "until", "until must be in the future")
        }
        try await db.transaction { tx in
            guard let user = try await User.find(userID, on: tx) else { throw APIError.notFound() }
            user.suspendedAt = now
            user.suspendedUntil = request.until
            user.suspensionReason = reason
            try await user.update(on: tx)
            try await log(
                .suspendUser, target: "user", id: userID, reportID: nil, actor: actor,
                note: reason, on: tx)
        }
    }

    static func unsuspend(_ userID: UUID, actor: String, on db: any Database) async throws {
        try await db.transaction { tx in
            guard let user = try await User.find(userID, on: tx) else { throw APIError.notFound() }
            user.suspendedAt = nil
            user.suspendedUntil = nil
            user.suspensionReason = nil
            try await user.update(on: tx)
            try await log(
                .unsuspendUser, target: "user", id: userID, reportID: nil, actor: actor, on: tx)
        }
    }

    // MARK: - Status

    private struct BeatRow: Decodable {
        var loop: String
        var lastBeatAt: Date

        enum CodingKeys: String, CodingKey {
            case loop
            case lastBeatAt = "last_beat_at"
        }
    }

    /// Every registered worker loop plus any loop that left a heartbeat, and row counts.
    static func status(registeredLoops: [String], on db: any Database, now: Date = Date())
        async throws -> AdminStatusResponse
    {
        let sql = try PushOutbox.sqlDatabase(db)
        let beats = try await sql.raw("SELECT loop, last_beat_at FROM worker_heartbeat")
            .all(decoding: BeatRow.self)
        let latest = Dictionary(
            beats.map { ($0.loop, $0.lastBeatAt) }, uniquingKeysWith: { max($0, $1) })
        let names = Set(registeredLoops).union(latest.keys).sorted()
        let workers = names.map { name in
            let beat = latest[name]
            return AdminWorkerStatus(
                name: name, lastBeatAt: beat,
                healthy: beat.map { now.timeIntervalSince($0) <= WorkerHealth.staleAfter } ?? false)
        }
        let counts = AdminCounts(
            users: try await User.query(on: db).count(),
            groups: try await Group.query(on: db).count(),
            posts: try await Post.query(on: db).count(),
            openReports: try await Report.query(on: db).filter(\.$status == .open).count(),
            pendingPush: try await PushOutboxEntry.query(on: db)
                .filter(\.$sentAt == nil)
                .filter(\.$failedAt == nil)
                .count())
        return AdminStatusResponse(workers: workers, counts: counts)
    }

    // MARK: - Helpers

    static func validatedNote(_ note: String?) throws -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        guard trimmed.count <= noteMax else {
            throw APIError.limitExceeded(field: "note", limit: noteMax)
        }
        return trimmed
    }

    static func log(
        _ action: ModerationAction, target: String, id: UUID, reportID: UUID?, actor: String,
        note: String? = nil, on db: any Database
    ) async throws {
        try await ModerationLogEntry(
            actor: actor, action: action, targetType: target, targetID: id, reportID: reportID,
            note: note
        ).create(on: db)
    }
}
