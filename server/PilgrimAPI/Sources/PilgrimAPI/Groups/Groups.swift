import Foundation

public enum GroupStatus: String, Sendable, Codable, CaseIterable {
    /// Normal. The group has an admin.
    case active
    /// The admin left; members elect a new one. Admin-only actions answer 409.
    case voting
    /// Deleted after a 7-day grace (`deleteAt`). Read and scrap only.
    case pendingDeletion
}

public enum GroupDeletionReason: String, Sendable, Codable, CaseIterable {
    /// Nobody voted in the first round of an admin election.
    case noVotes
    /// The admin deleted the group.
    case adminDeleted
}

/// Per-member notification switches (`PUT /groups/:id/notifications` → 204).
public struct GroupNotificationSettings: Equatable, Sendable, Codable {
    public var newPostPushEnabled: Bool
    public var dailyReportEnabled: Bool

    public init(newPostPushEnabled: Bool = true, dailyReportEnabled: Bool = true) {
        self.newPostPushEnabled = newPostPushEnabled
        self.dailyReportEnabled = dailyReportEnabled
    }
}

/// `GET /groups` items.
public struct GroupSummary: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var status: GroupStatus
    public var memberCount: Int
    public var isAdmin: Bool
    /// nil while voting.
    public var admin: UserSummary?
    public var unreadCount: Int
    public var latestPostAt: Date?
    public var notifications: GroupNotificationSettings
    public var voteEndsAt: Date?
    public var deleteAt: Date?

    public init(
        id: UUID, name: String, status: GroupStatus, memberCount: Int, isAdmin: Bool,
        admin: UserSummary?, unreadCount: Int, latestPostAt: Date?,
        notifications: GroupNotificationSettings, voteEndsAt: Date? = nil, deleteAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.memberCount = memberCount
        self.isAdmin = isAdmin
        self.admin = admin
        self.unreadCount = unreadCount
        self.latestPostAt = latestPostAt
        self.notifications = notifications
        self.voteEndsAt = voteEndsAt
        self.deleteAt = deleteAt
    }
}

/// `GET /groups/:id` and every group-changing call. JSON carries every `GroupSummary` field flat,
/// plus the detail fields.
public struct GroupDetail: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var status: GroupStatus
    public var memberCount: Int
    public var isAdmin: Bool
    public var admin: UserSummary?
    public var unreadCount: Int
    public var latestPostAt: Date?
    public var notifications: GroupNotificationSettings
    public var voteEndsAt: Date?
    public var deleteAt: Date?
    public var createdAt: Date
    public var createdBy: UserSummary?
    public var deletionReason: GroupDeletionReason?
    public var stickerCount: Int
    /// Admins only; nil for other members.
    public var activeInviteCount: Int?

    public init(
        summary: GroupSummary, createdAt: Date, createdBy: UserSummary?,
        deletionReason: GroupDeletionReason? = nil, stickerCount: Int,
        activeInviteCount: Int? = nil
    ) {
        self.id = summary.id
        self.name = summary.name
        self.status = summary.status
        self.memberCount = summary.memberCount
        self.isAdmin = summary.isAdmin
        self.admin = summary.admin
        self.unreadCount = summary.unreadCount
        self.latestPostAt = summary.latestPostAt
        self.notifications = summary.notifications
        self.voteEndsAt = summary.voteEndsAt
        self.deleteAt = summary.deleteAt
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.deletionReason = deletionReason
        self.stickerCount = stickerCount
        self.activeInviteCount = activeInviteCount
    }

    public var summary: GroupSummary {
        GroupSummary(
            id: id, name: name, status: status, memberCount: memberCount, isAdmin: isAdmin,
            admin: admin, unreadCount: unreadCount, latestPostAt: latestPostAt,
            notifications: notifications, voteEndsAt: voteEndsAt, deleteAt: deleteAt)
    }
}

/// `POST /groups` → 201 `GroupDetail`.
public struct CreateGroupRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    public var name: String

    public init(clientId: UUID, name: String) {
        self.clientId = clientId
        self.name = name
    }
}

/// `PATCH /groups/:id` (admin).
public struct UpdateGroupRequest: Equatable, Sendable, Codable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// `GET /groups/:id/members` items.
public struct MemberResponse: Equatable, Sendable, Codable {
    public var user: UserSummary
    public var isAdmin: Bool
    public var joinedAt: Date

    public init(user: UserSummary, isAdmin: Bool, joinedAt: Date) {
        self.user = user
        self.isAdmin = isAdmin
        self.joinedAt = joinedAt
    }
}

/// `GET /groups/:id/bans` items (admin).
public struct BanResponse: Equatable, Sendable, Codable {
    public var user: UserSummary
    public var bannedAt: Date

    public init(user: UserSummary, bannedAt: Date) {
        self.user = user
        self.bannedAt = bannedAt
    }
}

/// `POST /groups/:id/admin/transfer` (admin) → `GroupDetail`.
public struct TransferAdminRequest: Equatable, Sendable, Codable {
    public var userId: UUID

    public init(userId: UUID) {
        self.userId = userId
    }
}
