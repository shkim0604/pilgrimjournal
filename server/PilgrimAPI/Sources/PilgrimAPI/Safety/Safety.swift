import Foundation

public enum ReportTargetType: String, Sendable, Codable, CaseIterable {
    case post, comment, sticker, user
}

public enum ReportReason: String, Sendable, Codable, CaseIterable {
    case spam, harassment, inappropriate, selfHarm, other
}

/// `POST /reports` → 201 `ReportReceipt`. The server snapshots the target at this moment.
public struct CreateReportRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    public var targetType: ReportTargetType
    public var targetId: UUID
    public var groupId: UUID
    public var reason: ReportReason
    /// ≤ 500 characters.
    public var note: String?

    public init(
        clientId: UUID, targetType: ReportTargetType, targetId: UUID, groupId: UUID,
        reason: ReportReason, note: String? = nil
    ) {
        self.clientId = clientId
        self.targetType = targetType
        self.targetId = targetId
        self.groupId = groupId
        self.reason = reason
        self.note = note
    }
}

public struct ReportReceipt: Equatable, Sendable, Codable {
    public var id: UUID
    public var createdAt: Date

    public init(id: UUID, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}
