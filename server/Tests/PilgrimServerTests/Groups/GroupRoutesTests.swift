import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// `/groups/**` (design.md "그룹·멤버·투표"), against Postgres.
final class GroupRoutesTests: DatabaseTestCase {
    // MARK: - Create, read, rename, delete

    func testCreateIsIdempotentPerClientID() async throws {
        let me = try await fixtures.user("민지")
        let request = CreateGroupRequest(clientId: UUID(), name: "  수요 기도모임 ")

        let first = try await send(.POST, "api/v1/groups", as: me, json: request)
        expectEqual(first.status, .created, first.body.string)
        let detail = try decode(GroupDetail.self, from: first)
        expectEqual(detail.name, "수요 기도모임")
        expectTrue(detail.isAdmin)
        expectEqual(detail.memberCount, 1)
        expectEqual(detail.admin?.displayName, "민지")
        expectEqual(detail.createdBy?.id, me.id)
        expectEqual(detail.activeInviteCount, 0)

        var again = request
        again.name = "다른 이름"
        let second = try await send(.POST, "api/v1/groups", as: me, json: again)
        expectEqual(second.status, .ok)
        expectEqual(try decode(GroupDetail.self, from: second).id, detail.id)
        expectEqual(try await Group.query(on: db).count(), 1)

        let list = try await send(.GET, "api/v1/groups", as: me)
        expectEqual(try decode([GroupSummary].self, from: list).map(\.id), [detail.id])
    }

    func testCreateValidatesTheName() async throws {
        let me = try await fixtures.user()
        for name in ["   ", "줄\n바꿈", String(repeating: "가", count: 41)] {
            let response = try await send(
                .POST, "api/v1/groups", as: me,
                json: CreateGroupRequest(clientId: UUID(), name: name))
            expectEqual(response.status.code, 422, name)
            expectEqual(try errorBody(response).field, "name")
        }
    }

    func testCreatedGroupLimitIgnoresGroupsPendingDeletion() async throws {
        let me = try await fixtures.user()
        for index in 0..<APILimits.createdGroupsPerUser {
            let group = try await fixtures.group("그룹 \(index)", admin: me)
            if index == 0 {
                group.status = .pendingDeletion
                try await group.save(on: db)
            }
        }
        let create = CreateGroupRequest(clientId: UUID(), name: "하나 더")
        let allowed = try await send(.POST, "api/v1/groups", as: me, json: create)
        expectEqual(allowed.status, .created)

        let refused = try await send(
            .POST, "api/v1/groups", as: me, json: CreateGroupRequest(clientId: UUID(), name: "또"))
        try assertError(refused, .groupLimitReached)
        expectEqual(try errorBody(refused).limit, APILimits.createdGroupsPerUser)
    }

    func testSignupAndAccountChecks() async throws {
        let unnamed = try await fixtures.user(nil)
        try assertError(try await send(.GET, "api/v1/groups", as: unnamed), .signupRequired)

        let suspended = try await fixtures.user()
        suspended.suspendedAt = Date()
        try await suspended.save(on: db)
        try assertError(try await send(.GET, "api/v1/groups", as: suspended), .accountSuspended)

        let ghost = User(appleSub: "dev:ghost", displayName: "유령", timeZone: "Asia/Seoul")
        ghost.id = UUID()
        try assertError(try await send(.GET, "api/v1/groups", as: ghost), .unauthenticated)
    }

    func testRenameIsAdminOnly() async throws {
        let admin = try await fixtures.user("관리자")
        let member = try await fixtures.user("멤버")
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"

        try assertError(
            try await send(.PATCH, path, as: member, json: UpdateGroupRequest(name: "새 이름")),
            .forbidden)
        let renamed = try await send(
            .PATCH, path, as: admin, json: UpdateGroupRequest(name: "새 이름"))
        expectEqual(renamed.status, .ok)
        expectEqual(try decode(GroupDetail.self, from: renamed).name, "새 이름")

        let memberView = try decode(GroupDetail.self, from: try await send(.GET, path, as: member))
        expectFalse(memberView.isAdmin)
        expectNil(memberView.activeInviteCount)
    }

    func testDeleteSchedulesSevenDayGraceAndNotifiesMembers() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"

        let response = try await send(.DELETE, path, as: admin)
        expectEqual(response.status, .noContent)
        let detail = try decode(GroupDetail.self, from: try await send(.GET, path, as: member))
        expectEqual(detail.status, .pendingDeletion)
        expectEqual(detail.deletionReason, .adminDeleted)
        let deleteAt = try unwrap(detail.deleteAt)
        expectEqual(deleteAt.timeIntervalSinceNow, 7 * 86_400, accuracy: 60)

        let outbox = try await PushOutboxEntry.query(on: db).all()
        expectEqual(outbox.map { $0.$recipient.id }, [member.id!])

        // Repeating is a no-op; renaming is refused.
        expectEqual(try await send(.DELETE, path, as: admin).status, .noContent)
        try assertError(
            try await send(.PATCH, path, as: admin, json: UpdateGroupRequest(name: "x")),
            .groupPendingDeletion)
    }

    // MARK: - Leaving

    func testOrdinaryMemberLeaves() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"

        expectEqual(try await send(.POST, "\(path)/leave", as: member).status, .noContent)
        try assertError(try await send(.GET, path, as: member), .notFound)
        let detail = try decode(GroupDetail.self, from: try await send(.GET, path, as: admin))
        expectEqual(detail.memberCount, 1)
        expectTrue(detail.isAdmin)
    }

    func testLastMemberLeavingDeletesTheGroup() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let response = try await send(
            .POST, "api/v1/groups/\(group.id!.pilgrimString)/leave", as: admin)
        expectEqual(response.status, .noContent)
        expectNil(try await Group.find(group.id, on: db))
    }

    func testAdminLeavingWithOneMemberAppointsThem() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        _ = try await send(.POST, "api/v1/groups/\(group.id!.pilgrimString)/leave", as: admin)

        let reloaded = try unwrap(try await Group.find(group.id, on: db))
        expectEqual(reloaded.$admin.id, member.id)
        expectEqual(reloaded.status, .active)
        expectEqual(try await AdminVote.query(on: db).count(), 0)
    }

    func testAdminLeavingOpensAVoteAndLocksAdminActions() async throws {
        let admin = try await fixtures.user()
        let a = try await fixtures.user("가")
        let b = try await fixtures.user("나")
        let group = try await fixtures.group(admin: admin, members: [a, b])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"
        _ = try await send(.POST, "\(path)/leave", as: admin)

        let detail = try decode(GroupDetail.self, from: try await send(.GET, path, as: a))
        expectEqual(detail.status, .voting)
        expectNil(detail.admin)
        expectFalse(detail.isAdmin)
        let endsAt = try unwrap(detail.voteEndsAt)
        expectEqual(endsAt.timeIntervalSinceNow, 3 * 86_400, accuracy: 60)

        let vote = try decode(VoteResponse.self, from: try await send(.GET, "\(path)/vote", as: a))
        expectEqual(vote.round, 1)
        expectEqual(Set(vote.candidates.map(\.id)), [a.id!, b.id!])
        expectEqual(vote.eligibleCount, 2)
        expectEqual(try await PushOutboxEntry.query(on: db).count(), 2)

        try assertError(
            try await send(.PATCH, path, as: a, json: UpdateGroupRequest(name: "x")),
            .adminVoteInProgress)
        try assertError(try await send(.DELETE, path, as: a), .adminVoteInProgress)
        try assertError(
            try await send(.DELETE, "\(path)/members/\(b.id!.pilgrimString)", as: a),
            .adminVoteInProgress)
        try assertError(
            try await send(
                .POST, "\(path)/admin/transfer", as: a, json: TransferAdminRequest(userId: b.id!)),
            .adminVoteInProgress)
        try assertError(
            try await send(
                .POST, "\(path)/invites", as: a,
                json: CreateInviteRequest(clientId: UUID(), maxUses: 5)),
            .adminVoteInProgress)
    }

    func testHandOverAdminGroupsForAccountDeletion() async throws {
        let leaving = try await fixtures.user()
        let a = try await fixtures.user()
        let b = try await fixtures.user()
        let alone = try await fixtures.group("혼자", admin: leaving)
        let pair = try await fixtures.group("둘", admin: leaving, members: [a])
        let trio = try await fixtures.group("셋", admin: leaving, members: [a, b])
        let elsewhere = try await fixtures.group("남의 그룹", admin: a, members: [leaving, b])
        _ = try await GroupService.leave(a.id!, group: elsewhere.id!, dayLength: 86_400, on: db)
        // `elsewhere` is now voting between leaving and b.

        let summary = try await db.transaction { tx in
            try await GroupService.handOverAdminGroups(
                of: leaving.id!, dayLength: 86_400, on: tx)
        }
        expectEqual(summary.deleted, [alone.id!])
        expectEqual(summary.appointed, [pair.id!])
        expectEqual(summary.handedToVote, [trio.id!])
        let vote = try unwrap(try await VoteService.openVote(of: elsewhere.id!, on: db))
        expectEqual(vote.candidateIDs, [b.id!])
    }

    // MARK: - Members, bans, transfer

    func testKickBansUntilUnbanned() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user("강퇴")
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"
        let post = try await fixtures.post(by: member, in: group)

        try assertError(
            try await send(.DELETE, "\(path)/members/\(admin.id!.pilgrimString)", as: admin),
            .cannotTargetSelf)
        try assertError(
            try await send(.DELETE, "\(path)/members/\(admin.id!.pilgrimString)", as: member),
            .forbidden)
        expectEqual(
            try await send(.DELETE, "\(path)/members/\(member.id!.pilgrimString)", as: admin)
                .status, .noContent)
        expectNotNil(try await Post.find(post.id, on: db), "their posts stay")

        let bans = try decode(
            [BanResponse].self, from: try await send(.GET, "\(path)/bans", as: admin))
        expectEqual(bans.map(\.user.id), [member.id!])

        expectEqual(
            try await send(.DELETE, "\(path)/bans/\(member.id!.pilgrimString)", as: admin).status,
            .noContent)
        expectEqual(try await GroupBan.query(on: db).count(), 0)
        expectEqual(
            try await send(.DELETE, "\(path)/bans/\(member.id!.pilgrimString)", as: admin).status,
            .noContent)
    }

    func testTransferAdmin() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user("새 관리자")
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"

        try assertError(
            try await send(
                .POST, "\(path)/admin/transfer", as: admin,
                json: TransferAdminRequest(userId: outsider.id!)), .notFound)
        let response = try await send(
            .POST, "\(path)/admin/transfer", as: admin,
            json: TransferAdminRequest(userId: member.id!))
        expectEqual(response.status, .ok)
        let detail = try decode(GroupDetail.self, from: response)
        expectFalse(detail.isAdmin)
        expectEqual(detail.admin?.id, member.id)

        // The old admin now leaves as an ordinary member.
        _ = try await send(.POST, "\(path)/leave", as: admin)
        expectEqual(try await Group.find(group.id, on: db)?.$admin.id, member.id)
        expectEqual(try await AdminVote.query(on: db).count(), 0)
    }

    func testMembersArePagedInJoinOrder() async throws {
        let admin = try await fixtures.user("관리자")
        let group = try await fixtures.group(admin: admin)
        var expected = [admin.id!]
        for index in 0..<4 {
            let user = try await fixtures.user("멤버 \(index)")
            try await Membership(
                groupID: group.id!, userID: user.id!,
                joinedAt: Date().addingTimeInterval(Double(index + 1))
            ).create(on: db)
            expected.append(user.id!)
        }
        let path = "api/v1/groups/\(group.id!.pilgrimString)/members"
        var seen: [UUID] = []
        var cursor: String?
        repeat {
            let query = cursor.map { "?limit=2&cursor=\($0)" } ?? "?limit=2"
            let page = try decode(
                PilgrimAPI.Page<MemberResponse>.self,
                from: try await send(.GET, path + query, as: admin))
            expectLessThanOrEqual(page.items.count, 2)
            seen += page.items.map(\.user.id)
            if page.items.first?.user.id == admin.id { expectTrue(page.items[0].isAdmin) }
            cursor = page.nextCursor
        } while cursor != nil
        expectEqual(seen.first, admin.id)
        expectEqual(Set(seen), Set(expected))
        expectEqual(seen.count, expected.count)
    }

    // MARK: - Seen, notifications, unread

    func testSeenResetsUnreadAndNotificationsAreStored() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let path = "api/v1/groups/\(group.id!.pilgrimString)"
        try await fixtures.post(by: admin, in: group)
        try await fixtures.post(by: member, in: group)

        var summary = try decode(
            [GroupSummary].self, from: try await send(.GET, "api/v1/groups", as: member))
        expectEqual(summary.first?.unreadCount, 1, "own posts are not unread")
        expectNotNil(summary.first?.latestPostAt)

        expectEqual(
            try await send(.POST, "\(path)/seen", as: member, json: EmptyJSON()).status, .noContent)
        summary = try decode(
            [GroupSummary].self, from: try await send(.GET, "api/v1/groups", as: member))
        expectEqual(summary.first?.unreadCount, 0)

        let settings = GroupNotificationSettings(
            newPostPushEnabled: false, dailyReportEnabled: true)
        expectEqual(
            try await send(.PUT, "\(path)/notifications", as: member, json: settings).status,
            .noContent)
        let detail = try decode(GroupDetail.self, from: try await send(.GET, path, as: member))
        expectEqual(detail.notifications, settings)
    }

    // MARK: - 1.2.5 Non-members

    /// Every `groups/:id/**` route answers a non-member exactly like an unknown group.
    func testEveryGroupRouteIsNotFoundForNonMembers() async throws {
        let admin = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let invite = Invite(
            groupID: group.id!, code: InviteCode.generate().rawValue, createdByID: admin.id!,
            maxUses: 5, expiresAt: Date().addingTimeInterval(86_400))
        try await invite.create(on: db)

        for id in [group.id!, UUID()] {
            let path = "api/v1/groups/\(id.pilgrimString)"
            let other = admin.id!.pilgrimString
            let routes: [(HTTPMethod, String, (any Encodable)?)] = [
                (.GET, path, nil),
                (.PATCH, path, UpdateGroupRequest(name: "x")),
                (.DELETE, path, nil),
                (.POST, "\(path)/leave", nil),
                (.GET, "\(path)/members", nil),
                (.DELETE, "\(path)/members/\(other)", nil),
                (.GET, "\(path)/bans", nil),
                (.DELETE, "\(path)/bans/\(other)", nil),
                (.POST, "\(path)/admin/transfer", TransferAdminRequest(userId: admin.id!)),
                (.POST, "\(path)/seen", EmptyJSON()),
                (.PUT, "\(path)/notifications", GroupNotificationSettings()),
                (.GET, "\(path)/vote", nil),
                (.POST, "\(path)/vote/ballot", CastBallotRequest(candidateUserId: admin.id!)),
                (.POST, "\(path)/invites", CreateInviteRequest(clientId: UUID(), maxUses: 3)),
                (.GET, "\(path)/invites", nil),
                (.DELETE, "\(path)/invites/\(invite.code)", nil),
            ]
            for (method, route, body) in routes {
                let response = try await send(method, route, as: outsider, json: body)
                expectEqual(response.status, .notFound, "\(method) \(route)")
                expectEqual(try errorBody(response).code, .notFound, "\(method) \(route)")
            }
        }
        expectEqual(try await Group.find(group.id, on: db)?.status, .active)
        expectEqual(try await Invite.find(invite.id, on: db)?.revokedAt, nil)
    }
}
