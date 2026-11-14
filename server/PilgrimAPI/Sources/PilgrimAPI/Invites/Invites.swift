import Foundation

/// `POST /groups/:id/invites` (admin) → 201 `InviteResponse`.
public struct CreateInviteRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    /// 1…100 (`APILimits.inviteMaxUses`).
    public var maxUses: Int

    public init(clientId: UUID, maxUses: Int) {
        self.clientId = clientId
        self.maxUses = maxUses
    }
}

/// An invite as its group's admin sees it.
public struct InviteResponse: Equatable, Sendable, Codable {
    /// Normalized 12-character code (see `InviteCode`).
    public var code: String
    /// `https://pilgrim.delight-house.org/i/<code>`; QR codes encode the same URL.
    public var url: URL
    public var maxUses: Int
    public var useCount: Int
    public var expiresAt: Date
    public var createdAt: Date
    public var createdBy: UserSummary?

    public init(
        code: String, url: URL, maxUses: Int, useCount: Int, expiresAt: Date, createdAt: Date,
        createdBy: UserSummary?
    ) {
        self.code = code
        self.url = url
        self.maxUses = maxUses
        self.useCount = useCount
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.createdBy = createdBy
    }
}

/// `GET /invites/:code` (signed in): what the join screen shows before accepting.
public struct InvitePreviewResponse: Equatable, Sendable, Codable {
    public var code: String
    public var groupId: UUID
    public var groupName: String
    public var memberCount: Int
    public var invitedBy: UserSummary?
    public var expiresAt: Date
    public var alreadyMember: Bool
    /// true → the app shows the subscription screen before accepting.
    public var requiresSubscription: Bool

    public init(
        code: String, groupId: UUID, groupName: String, memberCount: Int,
        invitedBy: UserSummary?, expiresAt: Date, alreadyMember: Bool,
        requiresSubscription: Bool
    ) {
        self.code = code
        self.groupId = groupId
        self.groupName = groupName
        self.memberCount = memberCount
        self.invitedBy = invitedBy
        self.expiresAt = expiresAt
        self.alreadyMember = alreadyMember
        self.requiresSubscription = requiresSubscription
    }
}
