import Fluent
import Foundation
import PilgrimAPI
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Invites (design.md 6절) against Postgres.
final class InviteRoutesTests: DatabaseTestCase {
    private func createInvite(
        in group: Group, as admin: User, maxUses: Int = 5, clientID: UUID = UUID()
    ) async throws -> XCTHTTPResponse {
        try await send(
            .POST, "api/v1/groups/\(group.id!.pilgrimString)/invites", as: admin,
            json: CreateInviteRequest(clientId: clientID, maxUses: maxUses))
    }

    private func accept(_ code: String, as user: User) async throws -> XCTHTTPResponse {
        try await send(.POST, "api/v1/invites/\(code)/accept", as: user, json: EmptyJSON())
    }

    func testCreateListRevoke() async throws {
        let admin = try await fixtures.user("관리자")
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)/invites"

        let clientID = UUID()
        let created = try await createInvite(in: group, as: admin, maxUses: 3, clientID: clientID)
        expectEqual(created.status, .created, created.body.string)
        let invite = try decode(InviteResponse.self, from: created)
        expectNotNil(InviteCode(normalizing: invite.code))
        expectEqual(invite.url.absoluteString, "http://localhost:3100/i/\(invite.code)")
        expectEqual(invite.maxUses, 3)
        expectEqual(invite.useCount, 0)
        expectEqual(invite.createdBy?.displayName, "관리자")
        expectEqual(invite.expiresAt.timeIntervalSinceNow, 3 * 86_400, accuracy: 60)

        let repeated = try await createInvite(in: group, as: admin, maxUses: 9, clientID: clientID)
        expectEqual(repeated.status, .ok)
        expectEqual(try decode(InviteResponse.self, from: repeated).code, invite.code)

        try assertError(try await createInvite(in: group, as: member), .forbidden)
        try assertError(try await createInvite(in: group, as: admin, maxUses: 0), .limitExceeded)
        try assertError(try await createInvite(in: group, as: admin, maxUses: 101), .limitExceeded)
        try assertError(try await send(.GET, path, as: member), .forbidden)

        let list = try decode([InviteResponse].self, from: try await send(.GET, path, as: admin))
        expectEqual(list.map(\.code), [invite.code])

        // Revoking accepts the code typed loosely, and twice.
        let loose = InviteCode(normalizing: invite.code)!.grouped.lowercased()
        expectEqual(try await send(.DELETE, "\(path)/\(loose)", as: admin).status, .noContent)
        expectEqual(
            try await send(.DELETE, "\(path)/\(invite.code)", as: admin).status, .noContent)
        try assertError(
            try await send(.DELETE, "\(path)/\(InviteCode.generate().rawValue)", as: admin),
            .notFound)
        expectEqual(
            try decode([InviteResponse].self, from: try await send(.GET, path, as: admin)), [])
    }

    func testLiveInviteLimit() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        for _ in 0..<APILimits.activeInvitesPerGroup {
            try await Invite(
                groupID: group.id!, code: InviteCode.generate().rawValue, createdByID: admin.id!,
                maxUses: 1, expiresAt: Date().addingTimeInterval(86_400)
            ).create(on: db)
        }
        // Expired and revoked invites do not count.
        let expired = Invite(
            groupID: group.id!, code: InviteCode.generate().rawValue, createdByID: admin.id!,
            maxUses: 1, expiresAt: Date().addingTimeInterval(-60))
        try await expired.create(on: db)

        try assertError(try await createInvite(in: group, as: admin), .inviteLimitReached)
        let detail = try decode(
            GroupDetail.self,
            from: try await send(.GET, "api/v1/groups/\(group.id!.pilgrimString)", as: admin))
        expectEqual(detail.activeInviteCount, APILimits.activeInvitesPerGroup)
    }

    func testPreviewAndAccept() async throws {
        let admin = try await fixtures.user("초대한 사람")
        let joiner = try await fixtures.user("새 멤버")
        let group = try await fixtures.group("수요 기도모임", admin: admin)
        let invite = try decode(
            InviteResponse.self, from: try await createInvite(in: group, as: admin, maxUses: 2))

        let preview = try decode(
            InvitePreviewResponse.self,
            from: try await send(.GET, "api/v1/invites/\(invite.code)", as: joiner))
        expectEqual(preview.groupId, group.id)
        expectEqual(preview.groupName, "수요 기도모임")
        expectEqual(preview.memberCount, 1)
        expectEqual(preview.invitedBy?.displayName, "초대한 사람")
        expectFalse(preview.alreadyMember)
        expectFalse(preview.requiresSubscription)

        let loose = InviteCode(normalizing: invite.code)!.grouped.lowercased()
        let accepted = try await accept(loose, as: joiner)
        expectEqual(accepted.status, .ok, accepted.body.string)
        let detail = try decode(GroupDetail.self, from: accepted)
        expectEqual(detail.id, group.id)
        expectEqual(detail.memberCount, 2)

        // Accepting again counts nothing.
        expectEqual(try await accept(invite.code, as: joiner).status, .ok)
        expectEqual(try await Invite.query(on: db).first()?.useCount, 1)
        let membership = try await ContentVisibility.membership(
            of: joiner.id!, in: group.id!, on: db)
        expectNotNil(membership?.$invite.id)

        let again = try decode(
            InvitePreviewResponse.self,
            from: try await send(.GET, "api/v1/invites/\(invite.code)", as: joiner))
        expectTrue(again.alreadyMember)
    }

    func testPreviewIsOpenBeforeSignupButAcceptIsNot() async throws {
        let admin = try await fixtures.user()
        let unnamed = try await fixtures.user(nil)
        let group = try await fixtures.group(admin: admin)
        let invite = try decode(
            InviteResponse.self, from: try await createInvite(in: group, as: admin))
        expectEqual(
            try await send(.GET, "api/v1/invites/\(invite.code)", as: unnamed).status, .ok)
        try assertError(try await accept(invite.code, as: unnamed), .signupRequired)
    }

    func testAcceptRefusals() async throws {
        let admin = try await fixtures.user()
        let joiner = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        func invite(
            maxUses: Int = 5, useCount: Int = 0, expiresIn: TimeInterval = 86_400,
            revoked: Bool = false, in target: Group? = nil
        ) async throws -> String {
            let invite = Invite(
                groupID: (target ?? group).id!, code: InviteCode.generate().rawValue,
                createdByID: admin.id!, maxUses: maxUses,
                expiresAt: Date().addingTimeInterval(expiresIn))
            invite.useCount = useCount
            if revoked { invite.revokedAt = Date() }
            try await invite.create(on: db)
            return invite.code
        }

        try assertError(try await accept(InviteCode.generate().rawValue, as: joiner), .notFound)
        try assertError(try await accept("not-a-code", as: joiner), .notFound)
        try assertError(
            try await accept(try await invite(expiresIn: -60), as: joiner), .inviteExpired)
        try assertError(
            try await accept(try await invite(revoked: true), as: joiner), .inviteRevoked)
        try assertError(
            try await accept(try await invite(maxUses: 2, useCount: 2), as: joiner), .inviteFull)
        try assertError(
            try await send(.GET, "api/v1/invites/\(try await invite(expiresIn: -60))", as: joiner),
            .inviteExpired)

        let usable = try await invite()
        try await GroupBan(groupID: group.id!, userID: joiner.id!, bannedByID: admin.id!)
            .create(on: db)
        try assertError(try await accept(usable, as: joiner), .removedFromGroup)
        try await GroupBan.query(on: db).delete()

        group.status = .pendingDeletion
        try await group.save(on: db)
        try assertError(try await accept(usable, as: joiner), .groupPendingDeletion)
        group.status = .voting
        try await group.save(on: db)
        try assertError(try await accept(usable, as: joiner), .adminVoteInProgress)
        expectEqual(try await Invite.query(on: db).filter(\.$code == usable).first()?.useCount, 0)
    }

    func testJoinedGroupLimit() async throws {
        let admin = try await fixtures.user()
        let joiner = try await fixtures.user()
        for index in 0..<APILimits.joinedGroupsPerUser {
            let owner = try await fixtures.user("주인 \(index)")
            try await fixtures.group("그룹 \(index)", admin: owner, members: [joiner])
        }
        let group = try await fixtures.group(admin: admin)
        let invite = try decode(
            InviteResponse.self, from: try await createInvite(in: group, as: admin))
        try assertError(try await accept(invite.code, as: joiner), .groupLimitReached)
    }

    /// Concurrent accepts never push `use_count` past `max_uses`.
    func testConcurrentAcceptsRespectMaxUses() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let maxUses = 3
        let invite = try decode(
            InviteResponse.self,
            from: try await createInvite(in: group, as: admin, maxUses: maxUses))
        var joiners: [UUID] = []
        for index in 0..<8 { joiners.append(try await fixtures.user("동시 \(index)").id!) }

        let config = app.pilgrimConfig
        let database = app.db
        let code = invite.code
        let results = await withTaskGroup(of: APIErrorCode?.self) { tasks in
            for joiner in joiners {
                tasks.addTask {
                    do {
                        _ = try await InviteService.accept(
                            code, by: joiner, config: config, on: database)
                        return nil
                    } catch let error as APIError {
                        return error.code
                    } catch {
                        return .internal
                    }
                }
            }
            var codes: [APIErrorCode?] = []
            for await result in tasks { codes.append(result) }
            return codes
        }
        expectEqual(results.filter { $0 == nil }.count, maxUses)
        expectEqual(results.filter { $0 == .inviteFull }.count, joiners.count - maxUses)
        expectEqual(try await Invite.query(on: db).first()?.useCount, maxUses)
        expectEqual(
            try await Membership.query(on: db).filter(\.$group.$id == group.id!).count(),
            maxUses + 1)
    }
}
