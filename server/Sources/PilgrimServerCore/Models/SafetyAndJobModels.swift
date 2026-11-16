import Fluent
import Foundation
import PilgrimAPI

// Fluent models for design.md "Postgres 스키마 / 안전·작업"
// (`Migrations/CreateSafetyAndJobTables.swift`).

/// A viewer-only hide: exactly one of `post` (one post) and `targetUser` (that person, in every
/// group).
public final class Hide: Model, @unchecked Sendable {
    public static let schema = "hides"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "user_id") public var user: User
    @OptionalParent(key: "post_id") public var post: Post?
    @OptionalParent(key: "target_user_id") public var targetUser: User?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(id: UUID = UUID(), userID: UUID, postID: UUID) {
        self.id = id
        self.$user.id = userID
        self.$post.id = postID
        self.$targetUser.id = nil
    }

    public init(id: UUID = UUID(), userID: UUID, targetUserID: UUID) {
        self.id = id
        self.$user.id = userID
        self.$post.id = nil
        self.$targetUser.id = targetUserID
    }
}

/// `blocker` blocked `blocked`; applied in both directions (`ContentVisibility`).
public final class Block: Model, @unchecked Sendable {
    public static let schema = "blocks"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "blocker_id") public var blocker: User
    @Parent(key: "blocked_id") public var blocked: User
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(id: UUID = UUID(), blockerID: UUID, blockedID: UUID) {
        self.id = id
        self.$blocker.id = blockerID
        self.$blocked.id = blockedID
    }
}

public final class Report: Model, @unchecked Sendable {
    public static let schema = "reports"

    @ID(key: .id) public var id: UUID?
    @OptionalParent(key: "reporter_id") public var reporter: User?
    @OptionalParent(key: "group_id") public var group: Group?
    @Enum(key: "target_type") public var targetType: ReportTargetType
    /// No foreign key: the target may be gone while the report is kept (90 days).
    @Field(key: "target_id") public var targetID: UUID
    @OptionalParent(key: "target_user_id") public var targetUser: User?
    @Enum(key: "reason") public var reason: ReportReason
    @OptionalField(key: "note") public var note: String?
    @Field(key: "snapshot") public var snapshot: ReportSnapshot
    @Enum(key: "status") public var status: ReportStatus
    @OptionalField(key: "resolved_at") public var resolvedAt: Date?
    /// The console operator (`X-Admin-Actor`).
    @OptionalField(key: "resolved_by") public var resolvedBy: String?
    @Field(key: "client_id") public var clientID: UUID
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), reporterID: UUID?, groupID: UUID?, targetType: ReportTargetType,
        targetID: UUID, targetUserID: UUID?, reason: ReportReason, note: String?,
        snapshot: ReportSnapshot, clientID: UUID
    ) {
        self.id = id
        self.$reporter.id = reporterID
        self.$group.id = groupID
        self.targetType = targetType
        self.targetID = targetID
        self.$targetUser.id = targetUserID
        self.reason = reason
        self.note = note
        self.snapshot = snapshot
        self.status = .open
        self.clientID = clientID
    }
}

/// Operator actions, without content; never deleted.
public final class ModerationLogEntry: Model, @unchecked Sendable {
    public static let schema = "moderation_log"

    @ID(key: .id) public var id: UUID?
    @Field(key: "actor") public var actor: String
    @Enum(key: "action") public var action: ModerationAction
    @Field(key: "target_type") public var targetType: String
    @Field(key: "target_id") public var targetID: UUID
    @OptionalField(key: "report_id") public var reportID: UUID?
    @OptionalField(key: "note") public var note: String?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), actor: String, action: ModerationAction, targetType: String,
        targetID: UUID, reportID: UUID? = nil, note: String? = nil
    ) {
        self.id = id
        self.actor = actor
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.reportID = reportID
        self.note = note
    }
}

/// One notification for one recipient; the push loop fans it out to their devices.
public final class PushOutboxEntry: Model, @unchecked Sendable {
    public static let schema = "push_outbox"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "recipient_user_id") public var recipient: User
    @Enum(key: "kind") public var kind: PushKind
    @Field(key: "payload") public var payload: PushPayload
    @OptionalField(key: "collapse_id") public var collapseID: String?
    @Field(key: "attempts") public var attempts: Int
    @Field(key: "next_attempt_at") public var nextAttemptAt: Date
    @OptionalField(key: "sent_at") public var sentAt: Date?
    @OptionalField(key: "failed_at") public var failedAt: Date?
    @OptionalField(key: "last_error") public var lastError: String?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), recipientID: UUID, payload: PushPayload, collapseID: String? = nil,
        nextAttemptAt: Date = Date()
    ) {
        self.id = id
        self.$recipient.id = recipientID
        self.kind = payload.pilgrim.kind
        self.payload = payload
        self.collapseID = collapseID
        self.attempts = 0
        self.nextAttemptAt = nextAttemptAt
    }
}

public final class DailyReportLogEntry: Model, @unchecked Sendable {
    public static let schema = "daily_report_log"

    public enum Status: String, Codable, Sendable, CaseIterable {
        case sent, skipped
    }

    @ID(key: .id) public var id: UUID?
    @Parent(key: "user_id") public var user: User
    /// `YYYY-MM-DD` in the user's time zone.
    @Field(key: "report_date") public var reportDate: String
    @Field(key: "window_start") public var windowStart: Date
    @Field(key: "window_end") public var windowEnd: Date
    @Enum(key: "status") public var status: Status
    @Field(key: "item_count") public var itemCount: Int
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), userID: UUID, reportDate: LocalDate, windowStart: Date, windowEnd: Date,
        status: Status, itemCount: Int
    ) {
        self.id = id
        self.$user.id = userID
        self.reportDate = reportDate.description
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.status = status
        self.itemCount = itemCount
    }
}

/// Last iteration of each worker loop (`WorkerRunner` writes it; `/api/health` reads it).
public final class WorkerHeartbeat: Model, @unchecked Sendable {
    public static let schema = "worker_heartbeat"

    @ID(key: .id) public var id: UUID?
    @Field(key: "loop") public var loop: String
    @Field(key: "last_beat_at") public var lastBeatAt: Date
    @OptionalField(key: "last_error") public var lastError: String?
    @OptionalField(key: "last_error_at") public var lastErrorAt: Date?

    public init() {}
}
