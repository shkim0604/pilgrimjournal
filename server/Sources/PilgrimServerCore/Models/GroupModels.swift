import Fluent
import Foundation
import PilgrimAPI

// Fluent models for design.md "Postgres 스키마 / 그룹" (`Migrations/CreateGroupTables.swift`).

public final class Group: Model, @unchecked Sendable {
    public static let schema = "groups"

    @ID(key: .id) public var id: UUID?
    @Field(key: "name") public var name: String
    @OptionalParent(key: "created_by_id") public var createdBy: User?
    /// The only source of "is admin". nil while an admin vote runs (`status == .voting`).
    @OptionalParent(key: "admin_id") public var admin: User?
    @Enum(key: "status") public var status: GroupStatus
    @OptionalField(key: "delete_at") public var deleteAt: Date?
    @OptionalEnum(key: "deletion_reason") public var deletionReason: GroupDeletionReason?
    @OptionalField(key: "client_id") public var clientID: UUID?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    @Children(for: \.$group) public var memberships: [Membership]

    public init() {}

    public init(id: UUID = UUID(), name: String, createdByID: UUID?, clientID: UUID? = nil) {
        self.id = id
        self.name = name
        self.$createdBy.id = createdByID
        self.$admin.id = createdByID
        self.status = .active
        self.clientID = clientID
    }
}

public final class Membership: Model, @unchecked Sendable {
    public static let schema = "memberships"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    @Parent(key: "user_id") public var user: User
    @Field(key: "joined_at") public var joinedAt: Date
    @OptionalField(key: "last_seen_at") public var lastSeenAt: Date?
    @Field(key: "new_post_push_enabled") public var newPostPushEnabled: Bool
    @Field(key: "daily_report_enabled") public var dailyReportEnabled: Bool
    @OptionalParent(key: "invite_id") public var invite: Invite?

    public init() {}

    public init(
        id: UUID = UUID(), groupID: UUID, userID: UUID, joinedAt: Date = Date(),
        inviteID: UUID? = nil
    ) {
        self.id = id
        self.$group.id = groupID
        self.$user.id = userID
        self.joinedAt = joinedAt
        self.newPostPushEnabled = true
        self.dailyReportEnabled = true
        self.$invite.id = inviteID
    }
}

/// A removal from a group; blocks re-joining until the admin lifts it.
public final class GroupBan: Model, @unchecked Sendable {
    public static let schema = "group_bans"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    @Parent(key: "user_id") public var user: User
    @OptionalParent(key: "banned_by_id") public var bannedBy: User?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(id: UUID = UUID(), groupID: UUID, userID: UUID, bannedByID: UUID?) {
        self.id = id
        self.$group.id = groupID
        self.$user.id = userID
        self.$bannedBy.id = bannedByID
    }
}

public final class Invite: Model, @unchecked Sendable {
    public static let schema = "invites"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    /// Normalized 12-character Crockford base32 (`InviteCode`).
    @Field(key: "code") public var code: String
    @OptionalParent(key: "created_by_id") public var createdBy: User?
    @Field(key: "max_uses") public var maxUses: Int
    @Field(key: "use_count") public var useCount: Int
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "revoked_at") public var revokedAt: Date?
    @OptionalField(key: "client_id") public var clientID: UUID?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), groupID: UUID, code: String, createdByID: UUID?, maxUses: Int,
        expiresAt: Date, clientID: UUID? = nil
    ) {
        self.id = id
        self.$group.id = groupID
        self.code = code
        self.$createdBy.id = createdByID
        self.maxUses = maxUses
        self.useCount = 0
        self.expiresAt = expiresAt
        self.clientID = clientID
    }
}

/// One round of an admin election (design.md 5절).
public final class AdminVote: Model, @unchecked Sendable {
    public static let schema = "admin_votes"

    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, closed
    }

    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case elected, runoff, random, noVotes, restarted, groupDeleted
    }

    @ID(key: .id) public var id: UUID?
    @Parent(key: "group_id") public var group: Group
    /// 1, or 2 for the runoff.
    @Field(key: "round") public var round: Int
    @Field(key: "candidate_ids") public var candidateIDs: [UUID]
    @Field(key: "eligible_ids") public var eligibleIDs: [UUID]
    @Field(key: "started_at") public var startedAt: Date
    @Field(key: "ends_at") public var endsAt: Date
    @Enum(key: "status") public var status: Status
    @OptionalEnum(key: "outcome") public var outcome: Outcome?
    @OptionalParent(key: "elected_user_id") public var electedUser: User?
    @OptionalField(key: "closed_at") public var closedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), groupID: UUID, round: Int, candidateIDs: [UUID], eligibleIDs: [UUID],
        startedAt: Date, endsAt: Date
    ) {
        self.id = id
        self.$group.id = groupID
        self.round = round
        self.candidateIDs = candidateIDs
        self.eligibleIDs = eligibleIDs
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.status = .open
    }
}

public final class Ballot: Model, @unchecked Sendable {
    public static let schema = "ballots"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "vote_id") public var vote: AdminVote
    @Parent(key: "voter_id") public var voter: User
    @Parent(key: "candidate_id") public var candidate: User
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}

    public init(id: UUID = UUID(), voteID: UUID, voterID: UUID, candidateID: UUID) {
        self.id = id
        self.$vote.id = voteID
        self.$voter.id = voterID
        self.$candidate.id = candidateID
    }
}
