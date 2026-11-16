import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// `DELETE /me` against Postgres (design.md 13절).
final class AccountDeletionTests: DatabaseTestCase {
    private func deleteMe(_ user: User) async throws -> AccountDeletionResponse {
        var response: AccountDeletionResponse?
        try await app.test(.DELETE, "api/v1/me", headers: try headers(as: user)) {
            res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            response = try decode(AccountDeletionResponse.self, from: res)
        }
        return try XCTUnwrap(response)
    }

    func testAdminGroupsHandOverAndTheUserIsGone() async throws {
        let me = try await fixtures.user("나")
        let a = try await fixtures.user("가")
        let b = try await fixtures.user("나중")
        let c = try await fixtures.user("다")
        let voting = try await fixtures.group("투표", admin: me, members: [a, b])
        let appointed = try await fixtures.group("위임", admin: me, members: [c])
        let solo = try await fixtures.group("혼자", admin: me)
        let notMine = try await fixtures.group("남의 그룹", admin: a, members: [me])
        _ = try await fixtures.post(by: me, in: notMine)

        let result = try await deleteMe(me)
        XCTAssertFalse(result.alreadyDeleted)
        XCTAssertNotNil(result.deletedAt)
        XCTAssertEqual(result.groupsHandedToVote, [try voting.requireID()])
        XCTAssertEqual(result.groupsDeleted, [try solo.requireID()])

        // Vote opened among the others, round 1, 3 days.
        let votingGroup = try await unwrapAsync(try await Group.find(voting.id, on: db))
        XCTAssertEqual(votingGroup.status, .voting)
        XCTAssertNil(votingGroup.$admin.id)
        let vote = try await unwrapAsync(
            try await AdminVote.query(on: db).filter(\.$group.$id == voting.requireID()).first())
        XCTAssertEqual(vote.round, 1)
        XCTAssertEqual(Set(vote.candidateIDs), Set([try a.requireID(), try b.requireID()]))
        XCTAssertEqual(Set(vote.eligibleIDs), Set(vote.candidateIDs))
        XCTAssertEqual(
            vote.endsAt.timeIntervalSince(vote.startedAt),
            AdminVoteRules.roundLength(1, dayLength: AppConfig.defaultDayLength), accuracy: 1)

        // Sole remaining member becomes admin.
        let appointedGroup = try await unwrapAsync(try await Group.find(appointed.id, on: db))
        XCTAssertEqual(appointedGroup.$admin.id, c.id)
        XCTAssertEqual(appointedGroup.status, .active)

        // Empty group deleted; a group I only belonged to is untouched.
        let soloGone = try await Group.find(solo.id, on: db)
        XCTAssertNil(soloGone)
        let other = try await unwrapAsync(try await Group.find(notMine.id, on: db))
        XCTAssertEqual(other.$admin.id, a.id)

        // voteStarted goes to the voting group's remaining members, never to me.
        let pushes = try await PushOutboxEntry.query(on: db).all()
        XCTAssertEqual(
            Set(pushes.map { $0.$recipient.id }), Set([try a.requireID(), try b.requireID()]))

        // The user and everything hanging off them is gone.
        let user = try await User.find(me.id, on: db)
        XCTAssertNil(user)
        let memberships = try await Membership.query(on: db)
            .filter(\.$user.$id == me.requireID()).count()
        XCTAssertEqual(memberships, 0)
        let posts = try await Post.query(on: db).count()
        XCTAssertEqual(posts, 0)
    }

    func testCommentsWithTheDeletedUsersStickerShowARemovedSticker() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: bob, members: [alice])
        let post = try await fixtures.post(by: bob, in: group)
        let sticker = try await makeSticker(by: alice, in: group)
        let created = try await sendV1(
            .POST, "posts/\(try post.requireID())/comments", as: bob,
            json: CreateCommentRequest(
                clientId: UUID(), body: "", mediaIds: [], stickerId: try sticker.requireID()))
        assertStatus(created, .created)

        _ = try await deleteMe(alice)

        // The sticker went with Alice's account (cascade); Bob's comment stays.
        let page = try decode(
            APIPage<CommentResponse>.self,
            from: try await sendV1(.GET, "posts/\(try post.requireID())/comments", as: bob))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNil(page.items.first?.sticker)
        XCTAssertEqual(page.items.first?.stickerRemoved, true)
    }

    func testAppleTokensMoveToRevocationQueue() async throws {
        let me = try await fixtures.user()
        let cipher = app.authServices.appleTokenCipher
        for client in [BundleIDs.release, BundleIDs.debug] {
            try await AppleToken(
                userID: try me.requireID(), clientID: client,
                ciphertext: try cipher.encrypt("r.\(client)")
            ).create(on: db)
        }
        _ = try await deleteMe(me)

        let queued = try await AppleTokenRevocation.query(on: db).all()
        XCTAssertEqual(Set(queued.map(\.clientID)), BundleIDs.all)
        for row in queued {
            XCTAssertEqual(try cipher.decrypt(row.refreshTokenCiphertext), "r.\(row.clientID)")
            XCTAssertNil(row.completedAt)
            XCTAssertEqual(row.attempts, 0)
        }
        let remaining = try await AppleToken.query(on: db).count()
        XCTAssertEqual(remaining, 0)
    }

    func testSecondDeleteIsAlreadyDeleted() async throws {
        let me = try await fixtures.user()
        let first = try await deleteMe(me)
        XCTAssertFalse(first.alreadyDeleted)
        let second = try await deleteMe(me)
        XCTAssertTrue(second.alreadyDeleted)
        XCTAssertNil(second.deletedAt)
    }

    func testSuspendedUserCanStillDelete() async throws {
        let me = try await fixtures.user()
        me.suspendedAt = Date()
        try await me.save(on: db)
        let result = try await deleteMe(me)
        XCTAssertFalse(result.alreadyDeleted)
    }

    func testPendingDeletionGroupIsLeftAlone() async throws {
        let me = try await fixtures.user()
        let member = try await fixtures.user("멤버")
        let group = try await fixtures.group(admin: me, members: [member])
        group.status = .pendingDeletion
        group.deleteAt = Date().addingTimeInterval(86_400)
        try await group.save(on: db)

        let result = try await deleteMe(me)
        XCTAssertEqual(result.groupsHandedToVote, [])
        XCTAssertEqual(result.groupsDeleted, [])
        let stored = try await unwrapAsync(try await Group.find(group.id, on: db))
        XCTAssertEqual(stored.status, .pendingDeletion)
        let votes = try await AdminVote.query(on: db).count()
        XCTAssertEqual(votes, 0)
    }
}
