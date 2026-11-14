import Foundation

// Operator routes (`/internal/admin/v1`, design.md 14절). Called only by the web/admin console
// over the internal Docker network with `X-Admin-Token` and `X-Admin-Actor`.

public enum ReportStatus: String, Sendable, Codable, CaseIterable {
    case open, dismissed, actioned
}

public enum ReportResolution: String, Sendable, Codable, CaseIterable {
    case dismissed, actioned
}

/// What a report looked like when it was filed. Kept 90 days, even if the target is deleted.
public struct ReportSnapshot: Equatable, Sendable, Codable {
    public var authorId: UUID?
    public var authorName: String?
    public var title: String?
    public var body: String?
    public var items: [PrayerItem]?
    public var book: BookInfo?
    public var mediaIds: [UUID]
    public var capturedAt: Date

    public init(
        authorId: UUID?, authorName: String?, title: String? = nil, body: String? = nil,
        items: [PrayerItem]? = nil, book: BookInfo? = nil, mediaIds: [UUID] = [],
        capturedAt: Date
    ) {
        self.authorId = authorId
        self.authorName = authorName
        self.title = title
        self.body = body
        self.items = items
        self.book = book
        self.mediaIds = mediaIds
        self.capturedAt = capturedAt
    }
}

public struct AdminUserRef: Equatable, Sendable, Codable {
    public var id: UUID
    public var displayName: String?
    public var suspendedUntil: Date?

    public init(id: UUID, displayName: String?, suspendedUntil: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.suspendedUntil = suspendedUntil
    }
}

/// `GET /reports` items.
public struct AdminReport: Equatable, Sendable, Codable {
    public var id: UUID
    public var createdAt: Date
    public var status: ReportStatus
    public var reason: ReportReason
    public var note: String?
    public var targetType: ReportTargetType
    public var targetId: UUID
    public var groupId: UUID?
    public var groupName: String?
    public var reporter: AdminUserRef?
    public var targetUser: AdminUserRef?
    public var snapshot: ReportSnapshot
    public var resolvedAt: Date?
    public var resolvedBy: String?

    public init(
        id: UUID, createdAt: Date, status: ReportStatus, reason: ReportReason, note: String?,
        targetType: ReportTargetType, targetId: UUID, groupId: UUID?, groupName: String?,
        reporter: AdminUserRef?, targetUser: AdminUserRef?, snapshot: ReportSnapshot,
        resolvedAt: Date? = nil, resolvedBy: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.reason = reason
        self.note = note
        self.targetType = targetType
        self.targetId = targetId
        self.groupId = groupId
        self.groupName = groupName
        self.reporter = reporter
        self.targetUser = targetUser
        self.snapshot = snapshot
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
    }
}

/// The reported thing as it is now, if it still exists.
public struct AdminTarget: Equatable, Sendable, Codable {
    public var exists: Bool
    public var post: PostResponse?
    public var comment: CommentResponse?
    public var sticker: StickerResponse?

    public init(
        exists: Bool, post: PostResponse? = nil, comment: CommentResponse? = nil,
        sticker: StickerResponse? = nil
    ) {
        self.exists = exists
        self.post = post
        self.comment = comment
        self.sticker = sticker
    }
}

/// `GET /reports/:id`.
public struct AdminReportDetail: Equatable, Sendable, Codable {
    public var report: AdminReport
    public var liveTarget: AdminTarget?

    public init(report: AdminReport, liveTarget: AdminTarget?) {
        self.report = report
        self.liveTarget = liveTarget
    }
}

/// `POST /reports/:id/resolve` → `AdminReport`.
public struct ResolveReportRequest: Equatable, Sendable, Codable {
    public var resolution: ReportResolution
    public var note: String?

    public init(resolution: ReportResolution, note: String? = nil) {
        self.resolution = resolution
        self.note = note
    }
}

/// `POST /users/:id/suspend` → 204. `until == nil` suspends indefinitely.
public struct SuspendUserRequest: Equatable, Sendable, Codable {
    public var reason: String
    public var until: Date?

    public init(reason: String, until: Date? = nil) {
        self.reason = reason
        self.until = until
    }
}

/// One worker loop's heartbeat in `GET /status`.
public struct AdminWorkerStatus: Equatable, Sendable, Codable {
    public var name: String
    public var lastBeatAt: Date?
    public var healthy: Bool

    public init(name: String, lastBeatAt: Date?, healthy: Bool) {
        self.name = name
        self.lastBeatAt = lastBeatAt
        self.healthy = healthy
    }
}

public struct AdminCounts: Equatable, Sendable, Codable {
    public var users: Int
    public var groups: Int
    public var posts: Int
    public var openReports: Int
    public var pendingPush: Int

    public init(users: Int, groups: Int, posts: Int, openReports: Int, pendingPush: Int) {
        self.users = users
        self.groups = groups
        self.posts = posts
        self.openReports = openReports
        self.pendingPush = pendingPush
    }
}

/// `GET /status`.
public struct AdminStatusResponse: Equatable, Sendable, Codable {
    public var workers: [AdminWorkerStatus]
    public var counts: AdminCounts

    public init(workers: [AdminWorkerStatus], counts: AdminCounts) {
        self.workers = workers
        self.counts = counts
    }
}

/// `moderation_log.action`.
public enum ModerationAction: String, Sendable, Codable, CaseIterable {
    case deletePost, deleteComment, deleteSticker, suspendUser, unsuspendUser, resolveReport
}
