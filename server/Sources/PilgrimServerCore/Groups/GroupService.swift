import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// Group writes (design.md 5절, "그룹·멤버·투표"). Route handlers in `GroupsModule` call these;
/// account deletion (S1) and subscription expiry (S8) call `handOverAdminGroups(of:)` and
/// `leave(_:group:)` to hand groups over before removing a user.
enum GroupService {
    // MARK: - Create, rename, delete

    /// `POST /groups`: idempotent per `(creator, clientId)`. The creator becomes admin and first
    /// member. Refuses past 20 live created groups or 100 joined groups (409 `GROUP_LIMIT_REACHED`).
    static func create(
        _ request: CreateGroupRequest, by userID: UUID, on db: any Database, now: Date = Date()
    ) async throws -> Idempotency.Outcome<UUID> {
        let clientID = request.clientId
        let name = try validatedName(request.name)
        return try await Idempotency.findOrCreate(
            on: db,
            existing: { db in
                try await Group.query(on: db)
                    .filter(\.$createdBy.$id == userID)
                    .filter(\.$clientID == clientID)
                    .first()?.id
            },
            create: { tx in
                try await checkGroupLimits(creating: true, userID: userID, on: tx)
                let group = Group(name: name, createdByID: userID, clientID: clientID)
                try await group.create(on: tx)
                let groupID = try group.requireID()
                try await Membership(groupID: groupID, userID: userID, joinedAt: now)
                    .create(on: tx)
                return groupID
            })
    }

    /// 409 `GROUP_LIMIT_REACHED` when `userID` already belongs to 100 groups, or (when
    /// `creating`) already created 20 groups that are not scheduled for deletion.
    static func checkGroupLimits(creating: Bool, userID: UUID, on db: any Database) async throws {
        let joined = try await Membership.query(on: db).filter(\.$user.$id == userID).count()
        if joined >= APILimits.joinedGroupsPerUser {
            throw APIError(
                code: .groupLimitReached,
                message: "a user can belong to \(APILimits.joinedGroupsPerUser) groups",
                limit: APILimits.joinedGroupsPerUser)
        }
        guard creating else { return }
        let created = try await Group.query(on: db)
            .filter(\.$createdBy.$id == userID)
            .filter(\.$status != .pendingDeletion)
            .count()
        if created >= APILimits.createdGroupsPerUser {
            throw APIError(
                code: .groupLimitReached,
                message: "a user can create \(APILimits.createdGroupsPerUser) groups",
                limit: APILimits.createdGroupsPerUser)
        }
    }

    /// Trims surrounding whitespace and applies `APILimits.groupName` (1–40, no line breaks).
    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw APIError.validationFailed(field: "name", "the group name is empty")
        }
        if name.contains(where: \.isNewline) {
            throw APIError.validationFailed(field: "name", "the group name has a line break")
        }
        if name.count > APILimits.groupName.upperBound {
            throw APIError.limitExceeded(field: "name", limit: APILimits.groupName.upperBound)
        }
        return name
    }

    /// `PATCH /groups/:id` (admin).
    static func rename(_ groupID: UUID, to rawName: String, by viewer: UUID, on db: any Database)
        async throws
    {
        let name = try validatedName(rawName)
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer)
        group.name = name
        try await group.save(on: db)
    }

    /// `DELETE /groups/:id` (admin): `pendingDeletion` for 7 days (`adminDeleted`), not
    /// cancellable. Repeating it is a no-op. Members (but not the admin) are notified.
    static func scheduleDeletion(
        _ groupID: UUID, by viewer: UUID, dayLength: TimeInterval, on db: any Database,
        now: Date = Date()
    ) async throws {
        try await db.transaction { tx in
            try await lockGroup(groupID, on: tx)
            let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: tx)
            if group.status == .pendingDeletion, group.$admin.id == viewer { return }
            try GroupAccess.requireAdmin(group, viewer: viewer)
            group.status = .pendingDeletion
            group.deleteAt = now.addingTimeInterval(
                AdminVoteRules.deletionGrace(dayLength: dayLength))
            group.deletionReason = .adminDeleted
            try await group.save(on: tx)
            try await PushOutbox.enqueue(
                on: tx, groupEvent: .deletionScheduled, groupID: groupID, excluding: [viewer],
                now: now)
        }
    }

    // MARK: - Leaving and hand-over

    enum LeaveOutcome: Equatable, Sendable {
        /// An ordinary member left (or the admin of a group already scheduled for deletion).
        case left
        /// Nobody was left, so the group was deleted.
        case groupDeleted
        /// The admin left and the one remaining member became admin.
        case adminAppointed(UUID)
        /// The admin left; round 1 of an admin vote opened.
        case voteStarted(voteID: UUID)
    }

    /// `POST /groups/:id/leave`. A non-member gets 404.
    ///
    /// - The admin leaving hands the group over (`AdminVoteRules.start`): no one left → the
    ///   group is deleted; one member → they become admin; more → a 3-day vote opens.
    /// - Anyone leaving during a vote drops out as candidate and voter, and ballots by or for
    ///   them are discarded.
    /// - The last member leaving deletes the group.
    @discardableResult
    static func leave(
        _ userID: UUID, group groupID: UUID, dayLength: TimeInterval, on db: any Database,
        now: Date = Date()
    ) async throws -> LeaveOutcome {
        try await db.transaction { tx in
            try await lockGroup(groupID, on: tx)
            let (group, membership) = try await GroupAccess.memberGroup(
                groupID, viewer: userID, on: tx)
            try await membership.delete(on: tx)
            try await VoteService.removeParticipant(userID, fromOpenVoteOf: groupID, on: tx)

            let remaining = try await memberIDs(of: groupID, on: tx)
            if remaining.isEmpty {
                try await deleteGroup(groupID, on: tx)
                return .groupDeleted
            }
            guard group.$admin.id == userID else { return .left }
            if group.status == .pendingDeletion {
                group.$admin.id = nil
                try await group.save(on: tx)
                return .left
            }
            switch try await VoteService.handOver(
                group, remainingMembers: remaining, dayLength: dayLength, on: tx, now: now)
            {
            case .deleteGroup:
                try await deleteGroup(groupID, on: tx)
                return .groupDeleted
            case .appoint(let member):
                return .adminAppointed(member)
            case .openVote:
                guard let vote = try await VoteService.openVote(of: groupID, on: tx) else {
                    throw APIError(code: .internal, message: "vote did not open")
                }
                return .voteStarted(voteID: try vote.requireID())
            }
        }
    }

    struct HandOverSummary: Equatable, Sendable {
        var handedToVote: [UUID] = []
        var appointed: [UUID] = []
        var deleted: [UUID] = []
    }

    /// For account deletion (S1) and subscription removal (S8): leaves every group `userID`
    /// administers, handing each over as `leave` does. Call inside the caller's transaction,
    /// before deleting the user; memberships in other groups go with the user row's cascade.
    static func handOverAdminGroups(
        of userID: UUID, dayLength: TimeInterval, on db: any Database, now: Date = Date()
    ) async throws -> HandOverSummary {
        let groups = try await Group.query(on: db)
            .filter(\.$admin.$id == userID)
            .sort(\.$createdAt)
            .all()
        var summary = HandOverSummary()
        for group in groups {
            let groupID = try group.requireID()
            guard
                try await ContentVisibility.membership(of: userID, in: groupID, on: db) != nil
            else { continue }
            switch try await leave(userID, group: groupID, dayLength: dayLength, on: db, now: now)
            {
            case .voteStarted: summary.handedToVote.append(groupID)
            case .adminAppointed: summary.appointed.append(groupID)
            case .groupDeleted: summary.deleted.append(groupID)
            case .left: break
            }
        }
        // Votes elsewhere: drop the user as candidate and voter now rather than at the cascade,
        // so voters who picked them can choose again.
        let votingGroups = try await Membership.query(on: db)
            .filter(\.$user.$id == userID)
            .join(Group.self, on: \Membership.$group.$id == \Group.$id)
            .filter(Group.self, \.$status == .voting)
            .all()
        for membership in votingGroups {
            try await VoteService.removeParticipant(
                userID, fromOpenVoteOf: membership.$group.id, on: db)
        }
        return summary
    }

    /// For the worker's `votes` loop (S5): deletes up to `limit` `pendingDeletion` groups whose
    /// `delete_at` has passed (cascade and the `media_after_delete` trigger do the rest).
    /// Returns the deleted group IDs.
    @discardableResult
    static func deleteDueGroups(on db: any Database, now: Date = Date(), limit: Int = 100)
        async throws -> [UUID]
    {
        let sql = try PushOutbox.sqlDatabase(db)
        let rows = try await sql.raw(
            """
            DELETE FROM groups WHERE id IN (
                SELECT id FROM groups
                 WHERE status = 'pendingDeletion' AND delete_at <= \(bind: now)
                 ORDER BY delete_at LIMIT \(bind: limit)
                 FOR UPDATE SKIP LOCKED)
            RETURNING id
            """
        ).all()
        return try rows.map { try $0.decode(column: "id", as: UUID.self) }
    }

    // MARK: - Members, bans, transfer

    /// `DELETE /groups/:id/members/:userId` (admin): removes the member and records a ban, so no
    /// invite lets them back in until `unban`. Their posts and comments stay.
    static func kick(
        _ targetID: UUID, from groupID: UUID, by viewer: UUID, on db: any Database
    ) async throws {
        try await db.transaction { tx in
            let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: tx)
            try GroupAccess.requireAdmin(group, viewer: viewer)
            guard targetID != viewer else {
                throw APIError(
                    code: .cannotTargetSelf, message: "the admin cannot remove themselves")
            }
            guard
                let membership = try await ContentVisibility.membership(
                    of: targetID, in: groupID, on: tx)
            else { throw APIError.notFound("not a member") }
            try await membership.delete(on: tx)
            let sql = try PushOutbox.sqlDatabase(tx)
            try await sql.raw(
                """
                INSERT INTO group_bans (id, group_id, user_id, banned_by_id, created_at)
                VALUES (\(bind: UUID()), \(bind: groupID), \(bind: targetID), \(bind: viewer), now())
                ON CONFLICT (group_id, user_id) DO NOTHING
                """
            ).run()
        }
    }

    /// `GET /groups/:id/bans` (admin), newest first.
    static func bans(
        of groupID: UUID, viewer: UUID, config: AppConfig, on db: any Database, now: Date = Date()
    ) async throws -> [BanResponse] {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer, pendingDeletion: .allow)
        let bans = try await GroupBan.query(on: db)
            .filter(\.$group.$id == groupID)
            .sort(\.$createdAt, .descending)
            .all()
        let users = try await GroupUserSummaries.load(
            bans.map { $0.$user.id }, config: config, on: db, now: now)
        return bans.compactMap { ban in
            users[ban.$user.id].map { BanResponse(user: $0, bannedAt: ban.createdAt ?? now) }
        }
    }

    /// `DELETE /groups/:id/bans/:userId` (admin). Lifting a ban that does not exist succeeds.
    static func unban(_ targetID: UUID, in groupID: UUID, by viewer: UUID, on db: any Database)
        async throws
    {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        try GroupAccess.requireAdmin(group, viewer: viewer)
        try await GroupBan.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$user.$id == targetID)
            .delete()
    }

    /// `POST /groups/:id/admin/transfer` (admin): direct hand-over, no vote.
    static func transferAdmin(
        _ groupID: UUID, to targetID: UUID, by viewer: UUID, on db: any Database
    ) async throws {
        try await db.transaction { tx in
            try await lockGroup(groupID, on: tx)
            let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: tx)
            try GroupAccess.requireAdmin(group, viewer: viewer)
            guard targetID != viewer else {
                throw APIError(code: .cannotTargetSelf, message: "already the admin")
            }
            guard try await ContentVisibility.membership(of: targetID, in: groupID, on: tx) != nil
            else { throw APIError.notFound("not a member") }
            group.$admin.id = targetID
            try await group.save(on: tx)
        }
    }

    /// `GET /groups/:id/members`: ordered by join time, cursor-paged.
    static func members(
        of groupID: UUID, viewer: UUID, cursor: String?, limit: Int?, config: AppConfig,
        on db: any Database, now: Date = Date()
    ) async throws -> PilgrimAPI.Page<MemberResponse> {
        let (group, _) = try await GroupAccess.memberGroup(groupID, viewer: viewer, on: db)
        let pageSize = min(
            max(limit ?? PilgrimAPI.Page<MemberResponse>.defaultLimit, 1),
            PilgrimAPI.Page<MemberResponse>.maximumLimit)
        let after = try cursor.map(MemberCursor.init(encoded:))
        let sql = try PushOutbox.sqlDatabase(db)
        var afterClause: SQLQueryString = ""
        if let after {
            afterClause = """
                AND (m.joined_at, m.user_id) > \
                (TIMESTAMPTZ 'epoch' + \(bind: after.joinedAtMicros) * INTERVAL '1 microsecond', \
                \(bind: after.userID))
                """
        }
        let rows = try await sql.raw(
            """
            SELECT m.user_id, m.joined_at,
                   (EXTRACT(EPOCH FROM m.joined_at) * 1000000)::bigint AS joined_micros
            FROM memberships AS m
            WHERE m.group_id = \(bind: groupID) \(afterClause)
            ORDER BY m.joined_at, m.user_id
            LIMIT \(bind: pageSize + 1)
            """
        ).all()
        struct Item {
            var userID: UUID
            var joinedAt: Date
            var micros: Int64
        }
        let items = try rows.map {
            Item(
                userID: try $0.decode(column: "user_id", as: UUID.self),
                joinedAt: try $0.decode(column: "joined_at", as: Date.self),
                micros: try $0.decode(column: "joined_micros", as: Int64.self))
        }
        let page = Array(items.prefix(pageSize))
        let users = try await GroupUserSummaries.load(
            page.map(\.userID), config: config, on: db, now: now)
        let adminID = group.status == .voting ? nil : group.$admin.id
        let responses = page.compactMap { item in
            users[item.userID].map {
                MemberResponse(user: $0, isAdmin: item.userID == adminID, joinedAt: item.joinedAt)
            }
        }
        let next =
            items.count > pageSize
            ? page.last.map { MemberCursor(joinedAtMicros: $0.micros, userID: $0.userID).encoded }
            : nil
        return PilgrimAPI.Page(items: responses, nextCursor: next)
    }

    // MARK: - Per-member settings

    /// `POST /groups/:id/seen`: `last_seen_at = now` (unread counts restart from here).
    static func markSeen(_ groupID: UUID, by viewer: UUID, on db: any Database, now: Date = Date())
        async throws
    {
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: db)
        membership.lastSeenAt = now
        try await membership.save(on: db)
    }

    /// `PUT /groups/:id/notifications`.
    static func updateNotifications(
        _ groupID: UUID, _ settings: GroupNotificationSettings, by viewer: UUID,
        on db: any Database
    ) async throws {
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: db)
        membership.newPostPushEnabled = settings.newPostPushEnabled
        membership.dailyReportEnabled = settings.dailyReportEnabled
        try await membership.save(on: db)
    }

    // MARK: - Helpers

    static func memberIDs(of groupID: UUID, on db: any Database) async throws -> Set<UUID> {
        Set(
            try await Membership.query(on: db)
                .filter(\.$group.$id == groupID)
                .all()
                .map { $0.$user.id })
    }

    /// Deletes the group row; the cascade removes members, invites, votes, posts and media (the
    /// `media_after_delete` trigger queues the files).
    static func deleteGroup(_ groupID: UUID, on db: any Database) async throws {
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw("DELETE FROM groups WHERE id = \(bind: groupID)").run()
    }

    /// `SELECT … FOR UPDATE` on the group row, serializing leave / hand-over / invite accept.
    /// A missing group is not an error here (the membership check answers 404).
    static func lockGroup(_ groupID: UUID, on db: any Database) async throws {
        let sql = try PushOutbox.sqlDatabase(db)
        _ = try await sql.raw("SELECT id FROM groups WHERE id = \(bind: groupID) FOR UPDATE").all()
    }
}

/// The opaque `GET /groups/:id/members` cursor: `(joined_at µs, user_id)`, base64url.
struct MemberCursor: Equatable, Sendable {
    var joinedAtMicros: Int64
    var userID: UUID

    init(joinedAtMicros: Int64, userID: UUID) {
        self.joinedAtMicros = joinedAtMicros
        self.userID = userID
    }

    init(encoded: String) throws {
        guard let data = Data(base64URLEncoded: encoded),
            let text = String(data: data, encoding: .utf8)
        else { throw APIError.invalidRequest("bad cursor") }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let micros = Int64(parts[0]),
            let id = UUID(uuidString: String(parts[1]))
        else { throw APIError.invalidRequest("bad cursor") }
        self.init(joinedAtMicros: micros, userID: id)
    }

    var encoded: String {
        Data("\(joinedAtMicros)|\(userID.uuidString.lowercased())".utf8).base64URLEncodedString()
    }
}
