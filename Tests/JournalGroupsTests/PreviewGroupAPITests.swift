#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class PreviewGroupAPITests: XCTestCase {
    private let start = PilgrimDateFormat.date(from: "2026-11-14T03:00:00Z")!

    private func makeAPI(seeded: Bool = true) -> PreviewGroupAPI {
        let start = start
        return PreviewGroupAPI(now: { start }, seeded: seeded)
    }

    private func assertCode(
        _ code: APIErrorCode, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as GroupAPIError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testSeededWorldHasGroupsPostsAndAJoinableInvite() async throws {
        let api = makeAPI()
        let groups = try await api.groups()
        XCTAssertEqual(Set(groups.map(\.name)), ["수요 기도모임", "청년부 독서모임"])
        let wednesday = try XCTUnwrap(groups.first { $0.name == "수요 기도모임" })
        XCTAssertTrue(wednesday.isAdmin)
        XCTAssertGreaterThan(wednesday.unreadCount, 0)

        let feed = try await api.posts(groupID: wednesday.id, cursor: nil, limit: nil)
        XCTAssertEqual(feed.items.count, 3)
        XCTAssertEqual(feed.items.map(\.createdAt), feed.items.map(\.createdAt).sorted(by: >))

        let preview = try await api.invitePreview(code: "prev-1ew0-c0de")
        XCTAssertEqual(preview.groupName, "새벽기도 모임")
        XCTAssertFalse(preview.alreadyMember)
        let joined = try await api.acceptInvite(code: PreviewGroupAPI.sampleInviteCode)
        XCTAssertEqual(joined.memberCount, 3)
        let again = try await api.acceptInvite(code: PreviewGroupAPI.sampleInviteCode)
        XCTAssertEqual(again.id, joined.id, "accepting twice keeps the membership")
        let groupsAfterJoin = try await api.groups()
        XCTAssertEqual(groupsAfterJoin.count, 3)
    }

    func testPostsExpireThroughThePolicyAndWritesAreIdempotent() async throws {
        let api = makeAPI(seeded: false)
        let group = try await api.createGroup(CreateGroupRequest(clientId: UUID(), name: "모임"))
        let request = CreatePostRequest(
            clientId: UUID(), kind: .prayer, items: [PrayerItem(text: "면접")],
            deadline: LocalDate("2026-11-20"), timeZone: "Asia/Seoul")
        let post = try await api.createPost(groupID: group.id, request)
        XCTAssertEqual(post.expiresAt, PilgrimDateFormat.date(from: "2026-11-23T15:00:00Z"))
        let retried = try await api.createPost(groupID: group.id, request)
        XCTAssertEqual(retried.id, post.id)

        let comment = CreateCommentRequest(clientId: UUID(), body: "아멘")
        let first = try await api.createComment(postID: post.id, comment)
        let second = try await api.createComment(postID: post.id, comment)
        XCTAssertEqual(first.id, second.id)
        let reactions = try await api.react(postID: post.id, ReactionRequest(key: .emoji("🙏")))
        let reactedTwice = try await api.react(postID: post.id, ReactionRequest(key: .emoji("🙏")))
        XCTAssertEqual(reactions, reactedTwice)
        XCTAssertEqual(reactedTwice.first?.count, 1)

        await api.advanceTime(by: 10 * 86_400)
        await assertCode(.notFound) { _ = try await api.post(id: post.id) }
        let feed = try await api.posts(groupID: group.id, cursor: nil, limit: nil)
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testValidationErrorsCarryTheServerCodes() async throws {
        let api = makeAPI(seeded: false)
        let group = try await api.createGroup(CreateGroupRequest(clientId: UUID(), name: "모임"))
        await assertCode(.validationFailed) {
            _ = try await api.createPost(
                groupID: group.id,
                CreatePostRequest(
                    clientId: UUID(), kind: .prayer, items: [PrayerItem(text: "x")],
                    deadline: LocalDate("2026-11-01"), timeZone: "Asia/Seoul"))
        }
        await assertCode(.limitExceeded) {
            _ = try await api.createPost(
                groupID: group.id,
                CreatePostRequest(
                    clientId: UUID(), kind: .prayer,
                    items: Array(repeating: PrayerItem(text: "x"), count: 11),
                    timeZone: "Asia/Seoul"))
        }
        await assertCode(.extendNotAllowed) {
            let post = try await api.createPost(
                groupID: group.id,
                CreatePostRequest(
                    clientId: UUID(), kind: .testimony, body: "간증", timeZone: "Asia/Seoul"))
            _ = try await api.extendPost(id: post.id, ExtendPostRequest(clientId: UUID()))
        }
        await assertCode(.limitExceeded) {
            _ = try await api.createInvite(
                groupID: group.id, CreateInviteRequest(clientId: UUID(), maxUses: 101))
        }
        await assertCode(.notFound) { _ = try await api.group(id: UUID()) }
    }

    private func bookClub(_ api: PreviewGroupAPI) async throws -> (
        GroupDetail, admin: UUID, other: UUID
    ) {
        let summary = try await api.groups().first { $0.name == "청년부 독서모임" }!
        let group = try await api.group(id: summary.id)
        let me = await api.currentUserID
        let admin = try XCTUnwrap(group.admin?.id)
        let members = try await api.members(groupID: group.id, cursor: nil, limit: nil)
        let other = try XCTUnwrap(members.items.map(\.user.id).first { $0 != me && $0 != admin })
        return (group, admin, other)
    }

    func testAdminLeavingStartsAVoteThatTheBallotsDecide() async throws {
        let api = makeAPI()
        let (group, admin, other) = try await bookClub(api)
        XCTAssertFalse(group.isAdmin)

        try await api.simulateLeave(groupID: group.id, userID: admin)
        let voting = try await api.group(id: group.id)
        XCTAssertEqual(voting.status, .voting)
        XCTAssertNil(voting.admin)
        let vote = try await api.vote(groupID: group.id)
        XCTAssertEqual(vote.round, 1)
        XCTAssertEqual(vote.candidates.count, 2)
        XCTAssertEqual(vote.endsAt.timeIntervalSince(vote.startedAt), 3 * 86_400)
        await assertCode(.adminVoteInProgress) {
            _ = try await api.createInvite(
                groupID: group.id, CreateInviteRequest(clientId: UUID(), maxUses: 5))
        }
        await assertCode(.invalidCandidate) {
            _ = try await api.castBallot(
                groupID: group.id, CastBallotRequest(candidateUserId: admin))
        }

        let afterBallot = try await api.castBallot(
            groupID: group.id, CastBallotRequest(candidateUserId: other))
        XCTAssertEqual(afterBallot.myBallot, other)
        XCTAssertEqual(afterBallot.ballotCount, 1)

        await api.advanceTime(by: 3 * 86_400)
        let decided = try await api.group(id: group.id)
        XCTAssertEqual(decided.status, .active)
        XCTAssertEqual(decided.admin?.id, other)
        await assertCode(.notFound) { _ = try await api.vote(groupID: group.id) }
    }

    func testAVoteWithoutBallotsSchedulesDeletionAfterAGrace() async throws {
        let api = makeAPI()
        let (group, admin, _) = try await bookClub(api)
        try await api.simulateLeave(groupID: group.id, userID: admin)
        await api.advanceTime(by: 3 * 86_400)

        let pending = try await api.group(id: group.id)
        XCTAssertEqual(pending.status, .pendingDeletion)
        XCTAssertEqual(pending.deletionReason, .noVotes)
        await assertCode(.groupPendingDeletion) {
            _ = try await api.createPost(
                groupID: group.id,
                CreatePostRequest(
                    clientId: UUID(), kind: .testimony, body: "간증", timeZone: "Asia/Seoul"))
        }
        await api.advanceTime(by: 7 * 86_400)
        await assertCode(.notFound) { _ = try await api.group(id: group.id) }
    }

    func testTheOnlyMemberLeftBecomesAdmin() async throws {
        let api = makeAPI()
        let (group, admin, other) = try await bookClub(api)
        try await api.simulateLeave(groupID: group.id, userID: other)
        try await api.simulateLeave(groupID: group.id, userID: admin)
        let solo = try await api.group(id: group.id)
        XCTAssertTrue(solo.isAdmin)
        XCTAssertEqual(solo.status, .active)
    }

    func testBlockingHidesPostsCommentsAndReactions() async throws {
        let api = makeAPI()
        let wednesday = try await api.groups().first { $0.name == "수요 기도모임" }!
        let feed = try await api.posts(groupID: wednesday.id, cursor: nil, limit: nil)
        let prayer = try XCTUnwrap(feed.items.first { $0.kind == .prayer })
        XCTAssertEqual(prayer.reactions.first?.count, 2)
        let comments = try await api.comments(postID: prayer.id, cursor: nil, limit: nil)
        let commenter = try XCTUnwrap(comments.items.first?.author)

        try await api.block(userID: commenter.id)
        let after = try await api.post(id: prayer.id)
        XCTAssertEqual(after.commentCount, 0)
        XCTAssertEqual(
            after.reactions.first?.count, 1, "the blocked user's reaction is not counted")
        try await api.block(userID: prayer.author.id)
        await assertCode(.notFound) { _ = try await api.post(id: prayer.id) }
        let blocked = try await api.blockedUsers()
        XCTAssertEqual(blocked.count, 2)
        await assertCode(.cannotTargetSelf) {
            try await api.block(userID: await api.currentUserID)
        }
    }

    func testDailyReportCountsActivityInTheWindow() async throws {
        let api = makeAPI()
        let report = try await api.dailyReport(date: nil)
        XCTAssertEqual(report.windowEnd.timeIntervalSince(report.windowStart), 86_400)
        XCTAssertLessThanOrEqual(report.windowEnd, start)
        XCTAssertEqual(report.totalCount, report.groups.map(\.itemCount).reduce(0, +))
    }

    func testSignedOutCallsFailWithNotSignedIn() async throws {
        let api = PreviewGroupAPI(seeded: false, signedIn: false)
        await assertNotSignedIn { _ = try await api.me() }
        let session = try await api.signInForDevelopment(
            DevSignInRequest(devUser: "alice", bundleId: BundleIDs.debug, installationId: UUID()))
        XCTAssertTrue(session.user.profileComplete == false)
        await assertCode(.signupRequired) {
            _ = try await api.createGroup(CreateGroupRequest(clientId: UUID(), name: "모임"))
        }
        _ = try await api.updateMe(UpdateMeRequest(displayName: "앨리스"))
        _ = try await api.createGroup(CreateGroupRequest(clientId: UUID(), name: "모임"))

        let deletion = try await api.deleteAccount()
        XCTAssertFalse(deletion.alreadyDeleted)
        XCTAssertEqual(deletion.groupsDeleted.count, 1)
        let again = try await api.deleteAccount()
        XCTAssertTrue(again.alreadyDeleted)
    }

    private func assertNotSignedIn(
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected notSignedIn", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .notSignedIn, file: file, line: line)
            XCTAssertTrue((error as? GroupAPIError)?.requiresGroupSignIn == true)
        }
    }

    func testGroupAPIErrorHelpers() {
        let error = GroupAPIError.server(.inviteFull)
        XCTAssertEqual(error.code, .inviteFull)
        XCTAssertEqual(
            error, .server(status: 409, error: APIError(code: .inviteFull, message: "INVITE_FULL")))
        XCTAssertFalse(error.isRetryable)
        XCTAssertTrue(GroupAPIError.offline.isRetryable)
        XCTAssertTrue(GroupAPIError.server(.rateLimited).isRetryable)
        XCTAssertTrue(GroupAPIError.server(.refreshTokenReused).requiresGroupSignIn)
        XCTAssertFalse(GroupAPIError.server(.tokenExpired).requiresGroupSignIn)
    }
}
#endif
