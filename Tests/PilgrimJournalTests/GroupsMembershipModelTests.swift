#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import UniformTypeIdentifiers
import XCTest

final class GroupsMembershipRulesTests: XCTestCase {
    // MARK: Invite limits

    func testInviteMaxUsesBounds() {
        XCTAssertEqual(GroupInviteRules.maxUsesRange, 1...100)
        XCTAssertNil(GroupInviteRules.maxUses(from: "0"))
        XCTAssertEqual(GroupInviteRules.maxUses(from: "1"), 1)
        XCTAssertEqual(GroupInviteRules.maxUses(from: " 42 "), 42)
        XCTAssertEqual(GroupInviteRules.maxUses(from: "100"), 100)
        XCTAssertNil(GroupInviteRules.maxUses(from: "101"))
        XCTAssertNil(GroupInviteRules.maxUses(from: "-3"))
        XCTAssertNil(GroupInviteRules.maxUses(from: "열"))
        XCTAssertNil(GroupInviteRules.maxUses(from: ""))
        XCTAssertFalse(GroupInviteRules.isValid(maxUses: 0))
        XCTAssertTrue(GroupInviteRules.isValid(maxUses: 100))
        XCTAssertEqual(GroupInviteRules.clamped(0), 1)
        XCTAssertEqual(GroupInviteRules.clamped(57), 57)
        XCTAssertEqual(GroupInviteRules.clamped(500), 100)
        XCTAssertTrue(GroupInviteRules.isValid(maxUses: GroupInviteRules.defaultMaxUses))
        XCTAssertEqual(GroupInviteRules.lifetimeDays, 3)
    }

    func testNameRules() {
        XCTAssertTrue(GroupNameRules.isValidGroupName("  수요 기도모임 "))
        XCTAssertFalse(GroupNameRules.isValidGroupName("   "))
        XCTAssertFalse(GroupNameRules.isValidGroupName(String(repeating: "가", count: 41)))
        XCTAssertTrue(GroupNameRules.isValidGroupName(String(repeating: "가", count: 40)))
        XCTAssertFalse(GroupNameRules.isValidDisplayName(String(repeating: "a", count: 31)))
        XCTAssertTrue(GroupNameRules.isValidDisplayName("민지"))
    }

    // MARK: Apple re-authentication

    private let nonce = GroupAppleNonce(raw: "abc")

    private func credential(_ user: String, token: String? = "token", code: String? = "code")
        -> GroupAppleCredential
    {
        GroupAppleCredential(
            user: user, identityToken: token.map { Data($0.utf8) },
            authorizationCode: code.map { Data($0.utf8) })
    }

    func testNonceIsHashedWithSHA256InLowercaseHex() {
        XCTAssertEqual(
            nonce.hashed, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let first = GroupAppleNonce.make()
        let second = GroupAppleNonce.make()
        XCTAssertEqual(first.raw.count, 64, "32 random bytes as hex")
        XCTAssertNotEqual(first.raw, second.raw)
        XCTAssertNotEqual(first.raw, first.hashed)
    }

    func testSameAppleUserGivesTheSignInProof() throws {
        let proof = try GroupAppleAuthorization.verify(
            credential("001.user"), journalUserIdentifier: " 001.user\n", nonce: nonce)
        XCTAssertEqual(
            proof,
            GroupAppleSignInProof(
                identityToken: "token", authorizationCode: "code", rawNonce: "abc"))
    }

    func testDifferentAppleUserIsRejected() {
        XCTAssertThrowsError(
            try GroupAppleAuthorization.verify(
                credential("002.other"), journalUserIdentifier: "001.user", nonce: nonce)
        ) { error in
            XCTAssertEqual(error as? GroupAppleAuthorizationError, .differentUser)
        }
        XCTAssertEqual(
            GroupAppleAuthorizationError.differentUser.message,
            "기록장에 로그인한 Apple 계정으로 인증해 주세요.")
    }

    func testMissingJournalUserOrTokensAreRejected() {
        for journal in [nil, "", "  "] as [String?] {
            XCTAssertThrowsError(
                try GroupAppleAuthorization.verify(
                    credential("001.user"), journalUserIdentifier: journal, nonce: nonce)
            ) { XCTAssertEqual($0 as? GroupAppleAuthorizationError, .noJournalUser) }
        }
        for broken in [
            credential("001.user", token: nil), credential("001.user", code: nil),
            credential("001.user", token: ""),
        ] {
            XCTAssertThrowsError(
                try GroupAppleAuthorization.verify(
                    broken, journalUserIdentifier: "001.user", nonce: nonce)
            ) { XCTAssertEqual($0 as? GroupAppleAuthorizationError, .missingToken) }
        }
        XCTAssertNil(GroupAppleAuthorizationError.cancelled.message)
    }

    // MARK: Credential store

    func testSessionAccountIsAOneWayHashOfTheAppleUser() {
        let account = GroupCredentialStore.account(forAppleUser: "001234.abcdef")
        XCTAssertEqual(account.count, 64)
        XCTAssertFalse(account.contains("001234"))
        XCTAssertEqual(account, GroupCredentialStore.account(forAppleUser: " 001234.abcdef "))
        XCTAssertNotEqual(account, GroupCredentialStore.account(forAppleUser: "001234.other"))
        XCTAssertEqual(GroupCredentialStore.service, "com.dhouse.PilgrimJournal.group-session")
        XCTAssertNotEqual(account, GroupCredentialStore.installationIDAccount)
    }

    func testInstallationIDIsMadeOnceAndKept() throws {
        let store = InMemoryGroupSecureItemStore()
        let first = try store.installationID()
        XCTAssertEqual(try store.installationID(), first)
        XCTAssertEqual(store.accounts, [GroupCredentialStore.installationIDAccount])

        store.save(Data("not-a-uuid".utf8), for: GroupCredentialStore.installationIDAccount)
        XCTAssertThrowsError(try store.installationID())
    }

    // MARK: Capabilities and leaving

    private func summary(
        isAdmin: Bool, status: GroupStatus, memberCount: Int = 4
    ) -> GroupSummary {
        GroupSummary(
            id: UUID(), name: "수요 기도모임", status: status, memberCount: memberCount,
            isAdmin: isAdmin, admin: nil, unreadCount: 0, latestPostAt: nil,
            notifications: GroupNotificationSettings())
    }

    func testAdminCapabilitiesByState() {
        let admin = GroupAdminCapabilities(group: summary(isAdmin: true, status: .active))
        XCTAssertTrue(admin.canRename && admin.canCreateInvites && admin.canRemoveMembers)
        XCTAssertTrue(admin.canTransferAdmin && admin.canDeleteGroup && admin.canManageBans)

        let member = GroupAdminCapabilities(group: summary(isAdmin: false, status: .active))
        XCTAssertFalse(member.hasAnyAdminAction)

        // Even a stale `isAdmin` from before the vote shows nothing while it is open.
        let voting = GroupAdminCapabilities(group: summary(isAdmin: true, status: .voting))
        XCTAssertFalse(voting.hasAnyAdminAction)
        XCTAssertTrue(voting.isVoting)

        let grace = GroupAdminCapabilities(group: summary(isAdmin: true, status: .pendingDeletion))
        XCTAssertTrue(grace.isPendingDeletion)
        XCTAssertFalse(grace.canCreateInvites || grace.canRename || grace.canDeleteGroup)
        XCTAssertFalse(grace.canRemoveMembers || grace.canTransferAdmin)
        XCTAssertTrue(grace.canManageInvites && grace.canManageBans, "cleanup stays possible")
    }

    func testLeavePlan() {
        XCTAssertEqual(
            GroupLeavePlan(group: summary(isAdmin: true, status: .active)), .adminChoosesSuccessor)
        XCTAssertEqual(GroupLeavePlan(group: summary(isAdmin: false, status: .active)), .leave)
        XCTAssertEqual(
            GroupLeavePlan(group: summary(isAdmin: true, status: .active, memberCount: 1)),
            .lastMember)
        XCTAssertEqual(GroupLeavePlan(group: summary(isAdmin: false, status: .voting)), .leave)
    }

    // MARK: Messages

    func testEachJoinRefusalHasItsOwnWords() {
        let codes: [APIErrorCode] = [
            .inviteExpired, .inviteRevoked, .inviteFull, .adminVoteInProgress,
            .groupPendingDeletion, .removedFromGroup, .notFound,
        ]
        let texts = codes.map { GroupMessages.joinText(for: .server($0)) }
        XCTAssertEqual(Set(texts).count, codes.count)
        XCTAssertEqual(
            GroupMessages.joinText(for: .server(.inviteFull)),
            "이 초대는 인원이 다 찼어요. 관리자에게 새 초대를 요청해 주세요.")
        XCTAssertEqual(GroupMessages.joinText(for: .offline), GroupMessages.offline)
        XCTAssertEqual(
            GroupMessages.text(for: .server(.clientUpgradeRequired)), GroupMessages.upgradeRequired)
    }

    func testErrorsAreNormalized() {
        XCTAssertEqual(GroupsController.normalize(GroupAPIError.offline), .offline)
        XCTAssertEqual(GroupsController.normalize(CancellationError()), .cancelled)
        XCTAssertEqual(GroupsController.normalize(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(GroupsController.normalize(URLError(.notConnectedToInternet)), .offline)
    }

    // MARK: QR and photos

    func testInviteQRCodeIsGenerated() throws {
        let code = try XCTUnwrap(InviteCode(normalizing: PreviewGroupAPI.sampleInviteCode))
        let image = try XCTUnwrap(GroupInviteQRCode.image(for: code.url()))
        XCTAssertGreaterThan(image.width, 200)
        XCTAssertEqual(image.width, image.height)
    }

    func testProfilePhotoIsShrunkToJPEGWithoutMetadata() throws {
        let source = try Self.makeImageData(width: 4_032, height: 3_024, withGPS: true)
        let photo = try GroupProfilePhotoPreparer.prepare(source)

        XCTAssertLessThanOrEqual(max(photo.width, photo.height), PhotoLimits.maxLongEdge)
        XCTAssertEqual(photo.width, 1_600)
        XCTAssertEqual(photo.height, 1_200)
        XCTAssertLessThanOrEqual(photo.jpegData.count, PhotoLimits.maxPhotoBytes)
        XCTAssertTrue(PhotoLimits.hasJPEGSignature(photo.jpegData))
        let output = try XCTUnwrap(CGImageSourceCreateWithData(photo.jpegData as CFData, nil))
        let properties =
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNoThrow(
            try PhotoLimits.validate(
                purpose: .profile, width: photo.width, height: photo.height,
                byteCount: photo.jpegData.count))
    }

    func testUnreadablePhotoIsRefused() {
        XCTAssertThrowsError(try GroupProfilePhotoPreparer.prepare(Data("not an image".utf8)))
    }

    /// A noisy PNG (so it does not compress to nothing) with a GPS block.
    static func makeImageData(width: Int, height: Int, withGPS: Bool) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var generator = SystemRandomNumberGenerator()
        for row in stride(from: 0, to: height, by: 64) {
            for column in stride(from: 0, to: width, by: 64) {
                context.setFillColor(
                    red: .random(in: 0...1, using: &generator),
                    green: .random(in: 0...1, using: &generator),
                    blue: .random(in: 0...1, using: &generator), alpha: 1)
                context.fill(CGRect(x: column, y: row, width: 64, height: 64))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if withGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.5665, kCGImagePropertyGPSLongitude: 126.978,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
final class GroupsMembershipSheetModelTests: XCTestCase {
    private typealias Fixtures = GroupsMembershipFixtures

    func testJoinWithATypedCodeInAnyCase() async throws {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        let join = GroupJoinModel(groups: groups, code: nil)
        join.codeText = "prev-1ew0-c0de"
        XCTAssertNotNil(join.code)

        await join.loadPreview()
        let preview = try XCTUnwrap(join.preview)
        XCTAssertEqual(preview.groupName, "새벽기도 모임")
        XCTAssertFalse(preview.alreadyMember)

        let joined = await join.accept()
        XCTAssertEqual(joined, preview.groupId)
        XCTAssertNotNil(groups.group(preview.groupId))
    }

    func testJoinFailureKeepsTheTypedCode() async throws {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let join = GroupJoinModel(
            groups: groups, code: InviteCode(normalizing: PreviewGroupAPI.sampleInviteCode))
        let typed = join.codeText
        XCTAssertEqual(typed, "PREV-1EW0-C0DE")

        await api.setFailure(.offline)
        await join.loadPreview()
        XCTAssertEqual(join.message, GroupMessages.offline)
        XCTAssertEqual(join.codeText, typed)

        await api.setFailure(nil)
        await join.loadPreview()
        XCTAssertNotNil(join.preview)
        XCTAssertNil(join.message)

        await api.setFailure(.server(.inviteFull))
        let joined = await join.accept()
        XCTAssertNil(joined)
        XCTAssertEqual(join.message, GroupMessages.joinText(for: .server(.inviteFull)))
        XCTAssertNotNil(join.preview, "the preview stays for the retry")
    }

    func testUnknownAndMalformedCodes() async {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        let join = GroupJoinModel(groups: groups, code: nil)

        join.codeText = "too-short"
        XCTAssertNil(join.code)
        await join.loadPreview()
        XCTAssertNotNil(join.message)

        join.codeText = "ZZZZ-ZZZZ-ZZZZ"
        join.codeDidChange()
        XCTAssertNil(join.message)
        await join.loadPreview()
        XCTAssertEqual(join.message, GroupMessages.joinText(for: .server(.notFound)))
    }

    func testInviteModelCreatesListsAndRevokes() async throws {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first { $0.isAdmin })
        let invites = GroupInviteModel(groups: groups, groupID: group.id)
        XCTAssertEqual(invites.capabilities?.canCreateInvites, true)
        await invites.load()
        XCTAssertTrue(invites.invites.isEmpty)

        invites.maxUses = 0
        await invites.create()
        XCTAssertNotNil(invites.message, "outside 1…100 never reaches the server")
        XCTAssertNil(invites.created)

        invites.maxUses = 100
        let before = Date()
        await invites.create()
        let created = try XCTUnwrap(invites.created)
        XCTAssertNil(invites.message)
        XCTAssertEqual(created.maxUses, 100)
        XCTAssertEqual(created.url, try XCTUnwrap(InviteCode(normalizing: created.code)).url())
        XCTAssertEqual(
            created.expiresAt.timeIntervalSince(before), 3 * 86_400, accuracy: 60,
            "invites last three days")
        XCTAssertEqual(invites.invites.map(\.code), [created.code])

        await invites.revoke(created)
        XCTAssertTrue(invites.invites.isEmpty)
        XCTAssertNil(invites.created)
        await invites.load()
        XCTAssertTrue(invites.invites.isEmpty)
    }

    func testControllerRefusesOutOfRangeInvitesBeforeTheServer() async throws {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = Fixtures.controller(api: api)
        await groups.start()
        let group = try XCTUnwrap(groups.groups.first { $0.isAdmin })
        for maxUses in [0, 101, -1] {
            do {
                _ = try await groups.createInvite(in: group.id, maxUses: maxUses, clientID: UUID())
                XCTFail("accepted \(maxUses)")
            } catch {
                XCTAssertEqual((error as? GroupAPIError)?.code, .limitExceeded)
            }
        }
        let calls = await api.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("createInvite") })
    }
}
#endif
