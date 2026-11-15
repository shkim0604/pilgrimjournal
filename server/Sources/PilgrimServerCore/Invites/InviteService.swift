import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// Group invites (design.md 6절): admin-made codes with `maxUses` 1…100 that last 3 days,
/// at most 20 live per group. Accepting is one transaction with a conditional `UPDATE`, so
/// concurrent accepts never exceed `max_uses`.
enum InviteService {
    /// Invites that are neither revoked nor expired (full ones count).
    static func liveInviteCount(_ groupID: UUID, on db: any Database, now: Date = Date())
        async throws -> Int
    {
        try await liveInvites(groupID, on: db, now: now).count()
    }

    static func liveInvites(_ groupID: UUID, on db: any Database, now: Date)
        -> QueryBuilder<Invite>
    {
        Invite.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$revokedAt == nil)
            .filter(\.$expiresAt > now)
    }

    // MARK: - Admin

    /// `POST /groups/:id/invites` (admin): 201 for a new invite, 200 with the first one for a
    /// repeated `clientId`. 409 `INVITE_LIMIT_REACHED` past 20 live invites.
    static func create(
        _ request: CreateInviteRequest, in groupID: UUID, by viewer: UUID, config: AppConfig,
        on db: any Database, now: Date = Date()
    ) async throws -> Idempotency.Outcome<InviteResponse> {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer)
        guard APILimits.inviteMaxUses.contains(request.maxUses) else {
            throw APIError.limitExceeded(
                field: "maxUses", limit: APILimits.inviteMaxUses.upperBound,
                "maxUses must be \(APILimits.inviteMaxUses)")
        }
        let clientID = request.clientId
        let maxUses = request.maxUses
        let lifetime = Double(APILimits.inviteLifetimeDays) * config.dayLength
        // A fresh code colliding with an existing one is a unique violation that `existing`
        // cannot explain; try a new code a few times.
        var attempt = 0
        while true {
            attempt += 1
            do {
                let outcome = try await Idempotency.findOrCreate(
                    on: db,
                    existing: { db in
                        try await Invite.query(on: db)
                            .filter(\.$createdBy.$id == viewer)
                            .filter(\.$clientID == clientID)
                            .first()
                    },
                    create: { tx in
                        try await GroupService.lockGroup(groupID, on: tx)
                        let live = try await liveInviteCount(groupID, on: tx, now: now)
                        if live >= APILimits.activeInvitesPerGroup {
                            throw APIError(
                                code: .inviteLimitReached,
                                message:
                                    "a group can have \(APILimits.activeInvitesPerGroup) live invites",
                                limit: APILimits.activeInvitesPerGroup)
                        }
                        let invite = Invite(
                            groupID: groupID, code: InviteCode.generate().rawValue,
                            createdByID: viewer, maxUses: maxUses,
                            expiresAt: now.addingTimeInterval(lifetime), clientID: clientID)
                        try await invite.create(on: tx)
                        return invite
                    })
                let response = try await response(outcome.value, config: config, on: db, now: now)
                return Idempotency.Outcome(value: response, created: outcome.created)
            } catch let error where Idempotency.isUniqueViolation(error) && attempt < 3 {
                continue
            }
        }
    }

    /// `GET /groups/:id/invites` (admin): live invites, newest first. Allowed while the group is
    /// scheduled for deletion.
    static func list(
        _ groupID: UUID, viewer: UUID, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> [InviteResponse] {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer, pendingDeletion: .allow)
        let invites = try await liveInvites(groupID, on: db, now: now)
            .sort(\.$createdAt, .descending)
            .all()
        let users = try await GroupUserSummaries.load(
            invites.compactMap { $0.$createdBy.id }, config: config, on: db, now: now)
        return invites.map { response($0, users: users, config: config, now: now) }
    }

    /// `DELETE /groups/:id/invites/:code` (admin). Revoking twice succeeds; a code from another
    /// group is 404.
    static func revoke(
        _ codeText: String, in groupID: UUID, by viewer: UUID, on db: any Database,
        now: Date = Date()
    ) async throws {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer, pendingDeletion: .allow)
        guard let code = InviteCode(normalizing: codeText),
            let invite = try await Invite.query(on: db)
                .filter(\.$code == code.rawValue)
                .filter(\.$group.$id == groupID)
                .first()
        else { throw APIError.notFound("no such invite") }
        guard invite.revokedAt == nil else { return }
        invite.revokedAt = now
        try await invite.save(on: db)
    }

    // MARK: - Joining

    /// `GET /invites/:code`: 404 for unknown codes, 410 for revoked or expired invites. A full
    /// invite still previews (accepting answers 409), and so does a group the viewer is in.
    static func preview(
        _ codeText: String, viewer: UUID, config: AppConfig, on db: any Database,
        now: Date = Date()
    ) async throws -> InvitePreviewResponse {
        let invite = try await find(codeText, on: db)
        let groupID = invite.$group.id
        let alreadyMember =
            try await ContentVisibility.membership(of: viewer, in: groupID, on: db) != nil
        if !alreadyMember { try usable(invite, now: now) }
        guard let group = try await Group.find(groupID, on: db) else {
            throw APIError.notFound("no such invite")
        }
        let memberCount = try await Membership.query(on: db)
            .filter(\.$group.$id == groupID)
            .count()
        let invitedBy = try await GroupUserSummaries.load(
            invite.$createdBy.id, config: config, on: db, now: now)
        return InvitePreviewResponse(
            code: invite.code, groupId: groupID, groupName: group.name, memberCount: memberCount,
            invitedBy: invitedBy, expiresAt: invite.expiresAt, alreadyMember: alreadyMember,
            requiresSubscription: try await GroupEntitlement.requiresSubscription(
                viewer, config: config, on: db, now: now))
    }

    /// `POST /invites/:code/accept`, in one transaction:
    ///
    /// 1. already a member → the group, nothing counted;
    /// 2. banned → 403 `REMOVED_FROM_GROUP`;
    /// 3. `voting` / `pendingDeletion` → 409;
    /// 4. 100 joined groups → 409 `GROUP_LIMIT_REACHED`;
    /// 5. the conditional `UPDATE`; no row → 410 `INVITE_EXPIRED` / `INVITE_REVOKED`,
    ///    409 `INVITE_FULL` or 404, re-read to tell which;
    /// 6. the membership.
    static func accept(
        _ codeText: String, by viewer: UUID, config: AppConfig, on db: any Database,
        now: Date = Date()
    ) async throws -> GroupDetail {
        guard let code = InviteCode(normalizing: codeText) else {
            throw APIError.notFound("no such invite")
        }
        let groupID = try await db.transaction { tx -> UUID in
            guard
                let invite = try await Invite.query(on: tx).filter(\.$code == code.rawValue)
                    .first()
            else { throw APIError.notFound("no such invite") }
            let groupID = invite.$group.id
            try await GroupService.lockGroup(groupID, on: tx)
            if try await ContentVisibility.membership(of: viewer, in: groupID, on: tx) != nil {
                return groupID
            }
            let banned = try await GroupBan.query(on: tx)
                .filter(\.$group.$id == groupID)
                .filter(\.$user.$id == viewer)
                .first()
            if banned != nil {
                throw APIError(code: .removedFromGroup, message: "removed from this group")
            }
            guard let group = try await Group.find(groupID, on: tx) else {
                throw APIError.notFound("no such invite")
            }
            switch group.status {
            case .voting:
                throw APIError(
                    code: .adminVoteInProgress, message: "an admin election is in progress")
            case .pendingDeletion:
                throw APIError(
                    code: .groupPendingDeletion, message: "the group is scheduled for deletion")
            case .active:
                break
            }
            try await GroupService.checkGroupLimits(creating: false, userID: viewer, on: tx)

            let sql = try PushOutbox.sqlDatabase(tx)
            let claimed = try await sql.raw(
                """
                UPDATE invites SET use_count = use_count + 1
                 WHERE code = \(bind: code.rawValue) AND revoked_at IS NULL
                   AND expires_at > \(bind: now) AND use_count < max_uses
                RETURNING id
                """
            ).first()
            guard let claimed else {
                guard let current = try await Invite.find(try invite.requireID(), on: tx) else {
                    throw APIError.notFound("no such invite")
                }
                try usable(current, now: now)
                throw APIError(code: .inviteFull, message: "invite has no remaining uses")
            }
            let inviteID = try claimed.decode(column: "id", as: UUID.self)
            try await Membership(
                groupID: groupID, userID: viewer, joinedAt: now, inviteID: inviteID
            )
            .create(on: tx)
            return groupID
        }
        return try await GroupViews.detail(
            groupID, viewer: viewer, config: config, on: db, now: now)
    }

    // MARK: - Helpers

    static func find(_ codeText: String, on db: any Database) async throws -> Invite {
        guard let code = InviteCode(normalizing: codeText),
            let invite = try await Invite.query(on: db).filter(\.$code == code.rawValue).first()
        else { throw APIError.notFound("no such invite") }
        return invite
    }

    /// 410 for a revoked or expired invite.
    static func usable(_ invite: Invite, now: Date) throws {
        if invite.revokedAt != nil {
            throw APIError(code: .inviteRevoked, message: "invite was revoked")
        }
        if invite.expiresAt <= now {
            throw APIError(code: .inviteExpired, message: "invite has expired")
        }
    }

    static func response(_ invite: Invite, config: AppConfig, on db: any Database, now: Date)
        async throws -> InviteResponse
    {
        let users = try await GroupUserSummaries.load(
            [invite.$createdBy.id].compactMap { $0 }, config: config, on: db, now: now)
        return response(invite, users: users, config: config, now: now)
    }

    static func response(
        _ invite: Invite, users: [UUID: UserSummary], config: AppConfig, now: Date
    ) -> InviteResponse {
        let code = InviteCode(normalizing: invite.code)
        return InviteResponse(
            code: invite.code,
            url: code?.url(base: config.publicBaseURL)
                ?? config.publicBaseURL.appendingPathComponent("i").appendingPathComponent(
                    invite.code),
            maxUses: invite.maxUses, useCount: invite.useCount, expiresAt: invite.expiresAt,
            createdAt: invite.createdAt ?? now,
            createdBy: invite.$createdBy.id.flatMap { users[$0] })
    }
}
