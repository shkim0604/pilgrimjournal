#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

@MainActor
final class GroupsMembershipControllerTests: XCTestCase {
    private typealias Fixtures = GroupsMembershipFixtures

    // MARK: Sign-in and sign-up

    func testSignedOutThenAppleSignInThenSignUpShowsGroups() async throws {
        let api = PreviewGroupAPI(seeded: false, signedIn: false)
        let authorizer = FakeGroupAppleAuthorizer(user: Fixtures.journalUser)
        let credentials = InMemoryGroupSecureItemStore()
        let groups = Fixtures.controller(
            api: api, authorizer: authorizer, credentials: credentials)
        XCTAssertEqual(groups.accountState, .unknown)

        await groups.start()
        XCTAssertEqual(groups.accountState, .signedOut)
        XCTAssertTrue(groups.accountState.needsOnboarding)
        XCTAssertNil(groups.lastError, "signed out is a state, not a connection notice")

        let signedIn = await groups.signInWithApple()
        XCTAssertTrue(signedIn)
        XCTAssertEqual(groups.accountState, .needsProfile)
        XCTAssertNil(groups.signInMessage)
        let nonce = try XCTUnwrap(authorizer.hashedNonces.first)
        XCTAssertEqual(nonce.count, 64)
        XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertTrue(credentials.accounts.contains(GroupCredentialStore.installationIDAccount))

        try await groups.completeProfile(displayName: "  민지 ", photo: nil)
        XCTAssertEqual(groups.accountState, .signedIn)
        XCTAssertEqual(groups.me?.displayName, "민지")
        XCTAssertTrue(groups.hasLoaded)
        XCTAssertTrue(groups.groups.isEmpty)
    }

    func testInvalidDisplayNameIsRejectedWithoutTheServer() async throws {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI(seeded: false, signedIn: true))
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let callsBefore = await api.calls.count

        for name in ["", "   ", String(repeating: "가", count: 31), "두\n줄"] {
            do {
                try await groups.completeProfile(displayName: name, photo: nil)
                XCTFail("accepted \(name.debugDescription)")
            } catch {
                XCTAssertEqual((error as? GroupAPIError)?.code, .validationFailed)
            }
        }
        let callsAfter = await api.calls.count
        XCTAssertEqual(callsAfter, callsBefore)
    }

    func testDifferentAppleUserIsRejectedBeforeAnythingReachesTheServer() async throws {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI(seeded: false, signedIn: false))
        let authorizer = FakeGroupAppleAuthorizer(user: "009999.someone-else")
        let groups = Fixtures.controller(api: api, authorizer: authorizer)
        await groups.start()

        let signedIn = await groups.signInWithApple()

        XCTAssertFalse(signedIn)
        XCTAssertEqual(groups.accountState, .signedOut)
        XCTAssertEqual(groups.signInMessage, GroupAppleAuthorizationError.differentUser.message)
        let calls = await api.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("signInWithApple") })
    }

    func testCancelledAppleSheetShowsNoMessage() async {
        let authorizer = FakeGroupAppleAuthorizer(
            user: Fixtures.journalUser, failure: GroupAppleAuthorizationError.cancelled)
        let groups = Fixtures.controller(
            api: PreviewGroupAPI(seeded: false, signedIn: false), authorizer: authorizer)
        await groups.start()

        let signedIn = await groups.signInWithApple()
        XCTAssertFalse(signedIn)
        XCTAssertNil(groups.signInMessage)
        XCTAssertEqual(groups.accountState, .signedOut)
    }

    func testNoJournalUserCannotSignIn() async {
        let groups = Fixtures.controller(
            api: PreviewGroupAPI(seeded: false, signedIn: false), journalUser: nil)
        let signedIn = await groups.signInWithApple()
        XCTAssertFalse(signedIn)
        XCTAssertEqual(groups.signInMessage, GroupAppleAuthorizationError.noJournalUser.message)
    }

    func testOfflineSignInKeepsTheStateAndSaysSo() async {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI(seeded: false, signedIn: false))
        let groups = Fixtures.controller(api: api)
        await groups.start()
        await api.setFailure(.offline)

        let signedIn = await groups.signInWithApple()
        XCTAssertFalse(signedIn)
        XCTAssertEqual(groups.accountState, .signedOut)
        XCTAssertEqual(groups.signInMessage, GroupMessages.offline)
    }

    // MARK: Server states

    func testOfflineStartShowsTheConnectionNoticeAndRetryRecovers() async {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await api.setFailure(.offline)

        await groups.start()
        XCTAssertEqual(groups.accountState, .unknown)
        XCTAssertEqual(groups.lastError, .offline)
        XCTAssertEqual(groups.errorMessage, String(localized: "그룹 서버에 연결할 수 없어요."))

        await api.setFailure(nil)
        await groups.start()
        XCTAssertEqual(groups.accountState, .signedIn)
        XCTAssertNil(groups.lastError)
        XCTAssertFalse(groups.groups.isEmpty)
    }

    func testOfflineRefreshKeepsTheLastList() async {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let loaded = groups.groups
        XCTAssertFalse(loaded.isEmpty)

        await api.setFailure(.timedOut)
        await groups.refresh()
        XCTAssertEqual(groups.groups, loaded)
        XCTAssertEqual(groups.accountState, .signedIn)
        XCTAssertEqual(groups.lastError, .timedOut)
    }

    func testLostGroupSessionSignsOutOfGroupsOnly() async {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await groups.start()
        XCTAssertFalse(groups.groups.isEmpty)

        await api.setFailure(.server(.refreshTokenReused))
        await groups.refresh()
        XCTAssertEqual(groups.accountState, .signedOut)
        XCTAssertTrue(groups.groups.isEmpty)
        XCTAssertNil(groups.me)
    }

    func testUpgradeRequiredReplacesTheGroupScreens() async {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await api.setFailure(.server(.clientUpgradeRequired))
        await groups.start()
        XCTAssertEqual(groups.accountState, .upgradeRequired)
        XCTAssertNil(groups.lastError)
    }

    func testSubscriptionStateAndHook() throws {
        func me(complete: Bool, entitlement: EntitlementResponse) -> MeResponse {
            MeResponse(
                id: UUID(), displayName: complete ? "나" : nil, profileComplete: complete,
                timeZone: "Asia/Seoul", dailyReportEnabled: true,
                dailyReportTime: .defaultDailyReport, createdAt: Date(),
                entitlement: entitlement)
        }
        let required = EntitlementResponse(subscriptionRequired: true, active: false, status: .none)
        let subscribed = EntitlementResponse(
            subscriptionRequired: true, active: true, status: .active)
        XCTAssertEqual(
            GroupsAccountState(me: me(complete: false, entitlement: required)), .needsProfile,
            "sign-up comes before the subscription screen")
        XCTAssertEqual(
            GroupsAccountState(me: me(complete: true, entitlement: required)), .needsSubscription)
        XCTAssertEqual(
            GroupsAccountState(me: me(complete: true, entitlement: subscribed)), .signedIn)
        XCTAssertEqual(
            GroupsAccountState(me: me(complete: true, entitlement: .notRequired)), .signedIn)
        XCTAssertTrue(GroupsAccountState.needsSubscription.hasGroupAccess)

        let groups = Fixtures.controller(api: PreviewGroupAPI())
        groups.requestSubscription()
        XCTAssertEqual(groups.presentedSheet, .subscription, "placeholder until A8")

        var asked = 0
        groups.presentedSheet = nil
        groups.onSubscriptionRequired = { asked += 1 }
        groups.requestSubscription()
        XCTAssertEqual(asked, 1)
        XCTAssertNil(groups.presentedSheet)
    }

    // MARK: Create, join, leave, delete

    func testCreateJoinLeaveAndDeleteRefreshTheList() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        await groups.start()
        XCTAssertEqual(groups.groups.count, 2)

        let clientID = UUID()
        let created = try await groups.createGroup(named: " 금요 철야 ", clientID: clientID)
        XCTAssertEqual(created.name, "금요 철야")
        XCTAssertTrue(created.isAdmin)
        XCTAssertEqual(groups.groups.count, 3)
        let again = try await groups.createGroup(named: " 금요 철야 ", clientID: clientID)
        XCTAssertEqual(again.id, created.id, "a retry with the same clientId makes no second group")
        XCTAssertEqual(groups.groups.count, 3)

        let code = try XCTUnwrap(InviteCode(normalizing: PreviewGroupAPI.sampleInviteCode))
        let preview = try await groups.previewInvite(code)
        XCTAssertFalse(preview.alreadyMember)
        let joined = try await groups.joinGroup(code: code)
        XCTAssertEqual(joined.id, preview.groupId)
        XCTAssertEqual(groups.groups.count, 4)
        XCTAssertNotNil(groups.group(joined.id))

        try await groups.leaveGroup(joined.id)
        XCTAssertNil(groups.group(joined.id))
        XCTAssertEqual(groups.groups.count, 3)

        try await groups.deleteGroup(created.id)
        let deleted = try XCTUnwrap(groups.group(created.id))
        XCTAssertEqual(deleted.status, .pendingDeletion)
        XCTAssertNotNil(deleted.deleteAt)
        XCTAssertFalse(GroupAdminCapabilities(group: deleted).canCreateInvites)
    }

    func testAGroupTheServerNoLongerShowsLeavesTheList() async throws {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        let ghost = try XCTUnwrap(groups.groups.first)
        // Pretend another device already left: the server answers 404 from now on.
        try await groups.api.leaveGroup(id: ghost.id)

        do {
            _ = try await groups.groupDetail(ghost.id)
            XCTFail("expected NOT_FOUND")
        } catch {
            XCTAssertEqual((error as? GroupAPIError)?.code, .notFound)
        }
        XCTAssertNil(groups.group(ghost.id))
    }

    func testNotificationSwitchesUpdateTheList() async throws {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first)
        let settings = GroupNotificationSettings(
            newPostPushEnabled: false, dailyReportEnabled: true)

        try await groups.updateNotifications(group.id, settings)
        XCTAssertEqual(groups.group(group.id)?.notifications, settings)
        await groups.refresh()
        XCTAssertEqual(groups.group(group.id)?.notifications, settings, "the server kept it")
    }

    // MARK: Pending invites

    func testInviteLinkWaitsForSignInAndSignUpThenOpensTheJoinSheet() async throws {
        let invites = PendingGroupInvite(isEnabled: true)
        let groups = Fixtures.controller(
            api: PreviewGroupAPI(seeded: false, signedIn: false), invites: invites)
        let code = try XCTUnwrap(InviteCode(normalizing: "abcd-efgh-jk12"))
        invites.add(code)

        groups.attachToSystemEvents()
        XCTAssertEqual(groups.pendingInviteCodes, [code])
        XCTAssertNil(groups.presentedSheet, "nothing opens before the account is known")

        await groups.start()
        XCTAssertEqual(groups.presentedSheet, .onboarding)
        XCTAssertEqual(groups.pendingInviteCodes, [code], "kept until sign-up is done")

        await groups.signInWithApple()
        XCTAssertEqual(groups.presentedSheet, .onboarding)
        XCTAssertEqual(groups.pendingInviteCodes, [code])

        try await groups.completeProfile(displayName: "하은", photo: nil)
        guard case .join(let request) = groups.presentedSheet else {
            return XCTFail(
                "expected the join sheet, got \(String(describing: groups.presentedSheet))")
        }
        XCTAssertEqual(request.code, code)
        XCTAssertTrue(groups.pendingInviteCodes.isEmpty)
    }

    func testInvitesArrivingWhileSignedInOpenOneAtATime() async throws {
        let invites = PendingGroupInvite(isEnabled: true)
        let groups = Fixtures.controller(api: PreviewGroupAPI(), invites: invites)
        groups.attachToSystemEvents()
        await groups.start()
        let first = try XCTUnwrap(InviteCode(normalizing: "AAAA-BBBB-CCCC"))
        let second = try XCTUnwrap(InviteCode(normalizing: "DDDD-EEEE-FFFF"))

        invites.add(first)
        invites.add(second)
        guard case .join(let shown) = groups.presentedSheet else {
            return XCTFail("expected the join sheet")
        }
        XCTAssertEqual(shown.code, first)
        XCTAssertEqual(groups.pendingInviteCodes, [second], "the second waits its turn")

        groups.presentedSheet = nil
        groups.sheetDidDismiss()
        guard case .join(let next) = groups.presentedSheet else {
            return XCTFail("expected the next join sheet")
        }
        XCTAssertEqual(next.code, second)
        XCTAssertTrue(groups.pendingInviteCodes.isEmpty)
    }

    func testSidebarEntryPointsFollowTheAccountState() async {
        let groups = Fixtures.controller(api: PreviewGroupAPI(seeded: false, signedIn: false))
        await groups.start()
        groups.beginCreateGroup()
        XCTAssertEqual(groups.presentedSheet, .onboarding)
        groups.presentedSheet = nil
        groups.beginJoin()
        XCTAssertEqual(groups.presentedSheet, .onboarding)

        let signedIn = Fixtures.controller(api: PreviewGroupAPI())
        await signedIn.start()
        signedIn.beginCreateGroup()
        XCTAssertEqual(signedIn.presentedSheet, .createGroup)
        signedIn.beginJoin()
        guard case .join(let request) = signedIn.presentedSheet else {
            return XCTFail("expected the join sheet")
        }
        XCTAssertNil(request.code, "typed-code entry")
    }

    // MARK: Admin vote

    /// Hands the seeded 수요 기도모임 to another member, who then leaves: the vote opens.
    private func openVote(_ groups: GroupsController, api: PreviewGroupAPI) async throws -> UUID {
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first { $0.isAdmin })
        XCTAssertTrue(GroupAdminCapabilities(group: group).hasAnyAdminAction)
        let members = try await api.members(groupID: group.id, cursor: nil, limit: nil).items
        let successor = try XCTUnwrap(members.first { $0.user.id != groups.me?.id })
        _ = try await groups.transferAdmin(group.id, to: successor.user.id)
        try await api.simulateLeave(groupID: group.id, userID: successor.user.id)
        await groups.refresh()
        return group.id
    }

    func testVotingHidesEveryAdminActionAndTheServerAgrees() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        let groupID = try await openVote(groups, api: api)

        let voting = try XCTUnwrap(groups.group(groupID))
        XCTAssertEqual(voting.status, .voting)
        let capabilities = GroupAdminCapabilities(group: voting)
        XCTAssertTrue(capabilities.isVoting)
        XCTAssertFalse(capabilities.hasAnyAdminAction)
        XCTAssertFalse(capabilities.canCreateInvites)
        XCTAssertFalse(capabilities.canRemoveMembers)
        XCTAssertFalse(capabilities.canDeleteGroup)
        XCTAssertEqual(GroupLeavePlan(group: voting), .leave)

        do {
            _ = try await groups.createInvite(in: groupID, maxUses: 5, clientID: UUID())
            XCTFail("invites are closed while voting")
        } catch {
            XCTAssertEqual((error as? GroupAPIError)?.code, .adminVoteInProgress)
        }
    }

    func testBallotIsSecretAndCanBeChanged() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        let groupID = try await openVote(groups, api: api)
        let vote = GroupVoteModel(groups: groups, groupID: groupID)

        await vote.load()
        let ballot = try XCTUnwrap(vote.vote)
        XCTAssertEqual(ballot.round, 1)
        XCTAssertFalse(vote.isRunoff)
        XCTAssertEqual(ballot.ballotCount, 0)
        XCTAssertEqual(ballot.eligibleCount, ballot.candidates.count)
        let me = try XCTUnwrap(ballot.candidates.first { vote.isMe($0) }, "I can vote for myself")
        let other = try XCTUnwrap(ballot.candidates.first { !vote.isMe($0) })

        XCTAssertFalse(vote.canCast, "nothing chosen yet")
        vote.selection = me.id
        XCTAssertTrue(vote.canCast)
        XCTAssertFalse(vote.isChangingBallot)
        await vote.cast()
        XCTAssertEqual(vote.vote?.myBallot, me.id)
        XCTAssertEqual(vote.vote?.ballotCount, 1)
        XCTAssertFalse(vote.canCast, "the same choice again changes nothing")

        vote.selection = other.id
        XCTAssertTrue(vote.isChangingBallot)
        await vote.cast()
        XCTAssertEqual(vote.vote?.myBallot, other.id)
        XCTAssertEqual(vote.vote?.ballotCount, 1, "a changed ballot is still one ballot")
    }

    func testClosedVoteRefreshesTheGroup() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        let groupID = try await openVote(groups, api: api)
        let vote = GroupVoteModel(groups: groups, groupID: groupID)
        await vote.load()
        let ballot = try XCTUnwrap(vote.vote)
        let candidate = try XCTUnwrap(ballot.candidates.first { vote.isMe($0) })
        vote.selection = candidate.id
        await vote.cast()

        await api.advanceTime(by: 3 * 86_400 + 1)
        await vote.load()
        XCTAssertTrue(vote.isClosed)
        XCTAssertEqual(groups.group(groupID)?.status, .active)
        XCTAssertEqual(groups.group(groupID)?.isAdmin, true, "my one ballot elected me")
    }

    // MARK: Settings

    func testSettingsAdminActionsKickUnbanTransfer() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first { $0.isAdmin })
        let settings = GroupSettingsModel(groups: groups, groupID: group.id)
        await settings.load()
        XCTAssertNil(settings.message)
        XCTAssertEqual(settings.members.count, group.memberCount)
        XCTAssertEqual(settings.leavePlan, .adminChoosesSuccessor)

        settings.nameText = "수요 기도 모임"
        XCTAssertTrue(settings.canSaveName)
        await settings.saveName()
        XCTAssertEqual(groups.group(group.id)?.name, "수요 기도 모임")
        XCTAssertFalse(settings.canSaveName)

        let target = try XCTUnwrap(settings.otherMembers.first)
        await settings.remove(target)
        XCTAssertFalse(settings.members.contains { $0.user.id == target.user.id })
        XCTAssertEqual(settings.bans.map(\.user.id), [target.user.id])
        XCTAssertEqual(groups.group(group.id)?.memberCount, group.memberCount - 1)

        let ban = try XCTUnwrap(settings.bans.first)
        await settings.unban(ban)
        XCTAssertTrue(settings.bans.isEmpty)

        let successor = try XCTUnwrap(settings.otherMembers.first)
        await settings.transferAdmin(to: successor)
        XCTAssertEqual(settings.capabilities?.canRemoveMembers, false)
        XCTAssertEqual(groups.group(group.id)?.isAdmin, false)
        XCTAssertEqual(settings.leavePlan, .leave)
    }

    func testTransferAndLeave() async throws {
        let api = PreviewGroupAPI()
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first { $0.isAdmin })
        let settings = GroupSettingsModel(groups: groups, groupID: group.id)
        await settings.load()
        let successor = try XCTUnwrap(settings.otherMembers.first)

        let left = await settings.transferAndLeave(to: successor)
        XCTAssertTrue(left)
        XCTAssertNil(groups.group(group.id))
    }

    func testFailedNotificationSwitchFlipsBack() async throws {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first)
        let settings = GroupSettingsModel(groups: groups, groupID: group.id)
        let before = settings.notifications

        await api.setFailure(.offline)
        await settings.setNotifications(
            GroupNotificationSettings(newPostPushEnabled: !before.newPostPushEnabled))
        XCTAssertEqual(settings.notifications, before)
        XCTAssertEqual(settings.message, GroupMessages.offline)
    }
}
#endif
