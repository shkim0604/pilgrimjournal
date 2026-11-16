import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Group lookups and permissions with the error answers of design.md 2절 and 5절 ("투표 중",
/// "유예 삭제", the permission columns), shared by every module that works inside a group:
/// Groups, Invites, Votes, Posts, Stickers and Media.
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
        return (try await group(groupID, on: db), membership)
    }

    /// The group, or 404 (it may have been deleted between the membership check and now).
    static func group(_ id: UUID, on db: any Database) async throws -> Group {
        guard let group = try await Group.find(id, on: db) else { throw APIError.notFound() }
        return group
    }

    /// New posts, comments, reactions, stickers, photos and discussion extensions are refused
    /// while the group waits to be deleted (409 `GROUP_PENDING_DELETION`; "읽기와 스크랩만 된다").
    /// Reading and taking one's own content down still work.
    static func requireWritable(_ group: Group) throws {
        if group.status == .pendingDeletion {
            throw APIError(
                code: .groupPendingDeletion, message: "the group is scheduled for deletion")
        }
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
            try requireWritable(group)
        case .active, .pendingDeletion:
            break
        }
        guard group.$admin.id == viewer else {
            throw APIError.forbidden("only the group admin can do this")
        }
    }

    /// Deleting a post, comment or sticker: its author always may; otherwise only the group's
    /// admin, and not while a new admin is being voted on (409 `ADMIN_VOTE_IN_PROGRESS`).
    static func requireCanDelete(authorID: UUID, viewer: UUID, group: Group) throws {
        if authorID == viewer { return }
        if group.status == .voting {
            throw APIError(
                code: .adminVoteInProgress,
                message: "only the author can delete while an admin vote is open")
        }
        guard group.$admin.id == viewer else {
            throw APIError.forbidden("only the author or the group admin can delete this")
        }
    }

    /// A required UUID path parameter; a malformed one is 404 like any unknown ID.
    static func uuidParameter(_ name: String, of req: Request) throws -> UUID {
        guard let text = req.parameters.get(name), let id = UUID(uuidString: text) else {
            throw APIError.notFound()
        }
        return id
    }
}
