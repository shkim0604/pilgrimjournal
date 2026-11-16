import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Group lookups with the error answers of design.md 2절 and 5절, shared by the Groups, Invites
/// and Votes routes (and usable by Posts/Stickers for "author or admin" checks).
enum GroupAccess {
    /// What an admin-only write may do while the group is `pendingDeletion`.
    enum PendingDeletionPolicy {
        /// Refused with 409 `GROUP_PENDING_DELETION` (rename, kick, unban, transfer, new invite).
        case refuse
        /// Allowed (reading lists, revoking an invite).
        case allow
    }

    /// The group and the caller's membership, or 404 `NOT_FOUND` for non-members and unknown
    /// groups alike.
    static func memberGroup(_ groupID: UUID, viewer: UUID, on db: any Database) async throws
        -> (group: Group, membership: Membership)
    {
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: db)
        guard let group = try await Group.find(groupID, on: db) else {
            throw APIError.notFound()
        }
        return (group, membership)
    }

    /// Refuses admin-only actions: 409 `ADMIN_VOTE_IN_PROGRESS` while voting (there is no admin),
    /// 409 `GROUP_PENDING_DELETION` when `pendingDeletion` and `policy == .refuse`, otherwise
    /// 403 `FORBIDDEN` unless `viewer` is the admin.
    static func requireAdmin(
        _ group: Group, viewer: UUID, pendingDeletion policy: PendingDeletionPolicy = .refuse
    ) throws {
        switch group.status {
        case .voting:
            throw APIError(
                code: .adminVoteInProgress, message: "an admin election is in progress")
        case .pendingDeletion where policy == .refuse:
            throw APIError(
                code: .groupPendingDeletion, message: "the group is scheduled for deletion")
        case .active, .pendingDeletion:
            break
        }
        guard group.$admin.id == viewer else {
            throw APIError.forbidden("only the group admin can do this")
        }
    }

    /// Whether `viewer` is the admin of an active group (for "author or admin" deletes). False
    /// while voting.
    static func isActingAdmin(_ group: Group, viewer: UUID) -> Bool {
        group.status != .voting && group.$admin.id == viewer
    }

    /// Parses a `:groupID`-style path parameter; an unparsable ID is a plain 404.
    static func uuidParameter(_ name: String, of req: Request) throws -> UUID {
        guard let text = req.parameters.get(name), let id = UUID(uuidString: text) else {
            throw APIError.notFound()
        }
        return id
    }
}
