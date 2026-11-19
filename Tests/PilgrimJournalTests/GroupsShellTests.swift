#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalGroups
import JournalSearch
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

final class GroupsFeatureTests: XCTestCase {
    func testOnInDebugAndOffInRelease() {
        XCTAssertTrue(GroupsFeature.resolve(environment: [:], isDebugBuild: true))
        XCTAssertFalse(GroupsFeature.resolve(environment: [:], isDebugBuild: false))
    }

    func testEnvironmentTurnsDebugOffButNeverTurnsReleaseOn() {
        for value in ["0", "false", "NO", "off"] {
            XCTAssertFalse(
                GroupsFeature.resolve(environment: ["PILGRIM_GROUPS": value], isDebugBuild: true))
        }
        XCTAssertTrue(
            GroupsFeature.resolve(environment: ["PILGRIM_GROUPS": "1"], isDebugBuild: true))
        XCTAssertFalse(
            GroupsFeature.resolve(environment: ["PILGRIM_GROUPS": "1"], isDebugBuild: false))
    }

    func testNoClientFactoryWhileOff() {
        XCTAssertNil(GroupsFeature.defaultAPIFactory(isEnabled: false))
        XCTAssertNotNil(GroupsFeature.defaultAPIFactory(isEnabled: true))
    }

    private let client = ClientHeader(
        platform: .ios, version: ClientVersion("1.2.0")!, build: "30",
        bundleID: BundleIDs.debug)

    private func choice(
        _ environment: [String: String], debug: Bool = true, tests: Bool = false
    ) -> GroupsFeature.ClientChoice {
        GroupsFeature.clientChoice(
            environment: environment, isDebugBuild: debug, isHostedByTests: tests,
            client: client)
    }

    func testLiveClientGoesToProductionByDefault() {
        XCTAssertEqual(choice([:]), .live(.production(client: client)))
        XCTAssertEqual(
            choice([:]),
            .live(
                GroupServerConfiguration(
                    serverURL: URL(string: "https://pilgrim.delight-house.org")!,
                    client: client)))
    }

    func testDebugServerOverride() {
        let local = choice(["PILGRIM_GROUP_SERVER_URL": "http://localhost:3100/api/v1/"])
        XCTAssertEqual(
            local,
            .live(
                GroupServerConfiguration(
                    serverURL: URL(string: "http://localhost:3100")!, client: client)))
        XCTAssertEqual(
            choice(["PILGRIM_GROUP_SERVER_URL": "not a url"]),
            .live(.production(client: client)), "an unusable value falls back to production")
        XCTAssertEqual(
            choice(["PILGRIM_GROUP_SERVER_URL": "http://localhost:3100"], debug: false),
            .live(.production(client: client)), "Release ignores the override")
    }

    func testPreviewOptInTestsAndPreviews() {
        XCTAssertEqual(choice(["PILGRIM_GROUP_API": "preview"]), .preview)
        XCTAssertEqual(choice(["PILGRIM_GROUP_API": "PREVIEW"]), .preview)
        XCTAssertEqual(
            choice(["PILGRIM_GROUP_API": "preview"], debug: false),
            .live(.production(client: client)), "Release never runs the fake server")
        XCTAssertEqual(choice([:], tests: true), .preview)
        XCTAssertEqual(choice(["XCODE_RUNNING_FOR_PREVIEWS": "1"]), .preview)
        XCTAssertTrue(GroupsFeature.isHostedByTests, "this very test run counts")
    }

    @MainActor
    func testFactoryBuildsTheLiveClientForTheAccount() throws {
        let store = InMemoryGroupCredentialStore(installationID: UUID())
        let factory = try XCTUnwrap(
            GroupsFeature.defaultAPIFactory(
                isEnabled: true, environment: ["PILGRIM_GROUP_SERVER_URL": "http://localhost:3100"],
                isDebugBuild: true, isHostedByTests: false, credentialStore: store))
        let api = try XCTUnwrap(factory("account-hash") as? URLSessionGroupAPI)
        XCTAssertEqual(api.session.account, "account-hash")
        XCTAssertEqual(api.configuration.serverURL, URL(string: "http://localhost:3100")!)

        let preview = try XCTUnwrap(
            GroupsFeature.defaultAPIFactory(isEnabled: true, environment: [:]))
        XCTAssertTrue(preview("account-hash") is PreviewGroupAPI, "tests get the fake server")
    }

    func testReleaseKeepsGroupsOff() {
        XCTAssertFalse(
            GroupsFeature.resolve(environment: ["PILGRIM_GROUPS": "1"], isDebugBuild: false))
        XCTAssertNil(
            GroupsFeature.defaultAPIFactory(
                isEnabled: GroupsFeature.resolve(environment: [:], isDebugBuild: false)))
    }
}

final class GroupKeychainCredentialStoreTests: XCTestCase {
    func testSessionAndInstallationIDShareTheGroupItems() throws {
        let items = InMemoryGroupSecureItemStore()
        let store = GroupKeychainCredentialStore(items: items)
        let credential = GroupCredential(
            accessToken: "access", accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
            refreshToken: "refresh", refreshTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
            userId: UUID())

        XCTAssertNil(try store.loadCredential(account: "user-a"))
        try store.saveCredential(credential, account: "user-a")
        XCTAssertEqual(try store.loadCredential(account: "user-a"), credential)
        XCTAssertNil(try store.loadCredential(account: "user-b"))
        try store.deleteCredential(account: "user-a")
        XCTAssertNil(try store.loadCredential(account: "user-a"))

        // The ID the sign-in body sends (`installationID()`) is the one the session sends.
        XCTAssertNil(try store.loadInstallationID())
        let id = try items.installationID()
        XCTAssertEqual(try store.loadInstallationID(), id)
        let other = UUID()
        try store.saveInstallationID(other)
        XCTAssertEqual(try items.installationID(), other)
        XCTAssertEqual(
            items.load(for: GroupCredentialStore.installationIDAccount),
            Data(other.uuidString.lowercased().utf8))
    }

    func testAMalformedItemReadsAsAnError() {
        let items = InMemoryGroupSecureItemStore()
        items.save(Data("not json".utf8), for: "user-a")
        items.save(Data("nope".utf8), for: GroupCredentialStore.installationIDAccount)
        let store = GroupKeychainCredentialStore(items: items)
        XCTAssertThrowsError(try store.loadCredential(account: "user-a"))
        XCTAssertThrowsError(try store.loadInstallationID())
    }
}

@MainActor
final class GroupsSelectionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-groups-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() throws -> AppModel {
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(url: paths.search.appending(path: "groups.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: UserDefaults(suiteName: "groups-\(UUID().uuidString)")!
        )
        model.groups = GroupsController(
            api: PreviewGroupAPI(),
            invites: PendingGroupInvite(isEnabled: true),
            notifications: GroupNotificationRouting(isEnabled: true))
        return model
    }

    func testSelectingAGroupClearsEveryOtherSelection() throws {
        let model = try makeModel()
        model.selectNotebook("교회")
        model.isPresentingSettings = true
        model.isPresentingEditor = true
        model.beginBatchSelection()
        let groupID = UUID()

        model.selectGroup(groupID)

        XCTAssertEqual(model.selectedGroupID, groupID)
        XCTAssertNil(model.selectedKind)
        XCTAssertNil(model.selectedNotebookName)
        XCTAssertNil(model.selectedSharedSpaceID)
        XCTAssertFalse(model.isPresentingSettings)
        XCTAssertFalse(model.isPresentingEditor)
        XCTAssertFalse(model.isBatchSelecting)
        XCTAssertNil(model.selectedEntryID)
    }

    func testKindNotebookAllEntriesAndSharedSpaceClearTheGroup() throws {
        let model = try makeModel()
        let groupID = UUID()

        model.selectGroup(groupID)
        model.selectGroupPost(UUID())
        model.selectKind(.prayer)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupPostID)

        model.selectGroup(groupID)
        model.selectNotebook("교회")
        XCTAssertNil(model.selectedGroupID)

        model.selectGroup(groupID)
        model.selectKind(nil)
        XCTAssertNil(model.selectedGroupID)

        model.selectGroup(groupID)
        model.clearSearchCriteria()
        XCTAssertNil(model.selectedGroupID)

        model.selectGroup(groupID)
        model.selectedSharedSpaceID = UUID()
        XCTAssertNil(model.selectedGroupID)

        model.selectGroup(groupID)
        XCTAssertNil(model.selectedSharedSpaceID)
    }

    func testSettingsAndNewEntryLeaveTheGroup() throws {
        let model = try makeModel()
        model.selectGroup(UUID())
        model.showSettings()
        XCTAssertNil(model.selectedGroupID)
        XCTAssertTrue(model.isPresentingSettings)

        model.selectGroup(UUID())
        XCTAssertFalse(model.isPresentingSettings)
        model.beginNewEntry()
        XCTAssertNil(model.selectedGroupID)
        XCTAssertTrue(model.isPresentingEditor)
    }

    func testPostSelectionBelongsToTheSelectedGroup() throws {
        let model = try makeModel()
        let postID = UUID()
        model.selectGroupPost(postID)
        XCTAssertNil(model.selectedGroupPostID, "no post without a group")

        let groupID = UUID()
        model.selectGroup(groupID)
        model.selectGroupPost(postID)
        XCTAssertEqual(model.selectedGroupPostID, postID)

        model.selectGroup(groupID)
        XCTAssertEqual(model.selectedGroupPostID, postID, "reselecting keeps the open post")

        model.selectGroup(UUID())
        XCTAssertNil(model.selectedGroupPostID)
    }

    func testNotificationRoutesSelectTheirScreen() throws {
        let model = try makeModel()
        let groupID = UUID()
        let postID = UUID()

        model.openGroupNotificationRoute(.post(groupID: groupID, postID: postID))
        XCTAssertEqual(model.selectedGroupID, groupID)
        XCTAssertEqual(model.selectedGroupPostID, postID)

        let other = UUID()
        model.openGroupNotificationRoute(.group(other))
        XCTAssertEqual(model.selectedGroupID, other)
        XCTAssertNil(model.selectedGroupPostID)

        model.openGroupNotificationRoute(.dailyReport)
        XCTAssertEqual(model.selectedGroupID, other)
    }
}

@MainActor
final class GroupsSessionTests: XCTestCase {
    private func makeController(
        root: URL, makeGroupAPI: GroupsFeature.APIFactory?,
        opener: GroupNotificationOpener = GroupNotificationOpener(
            isEnabled: true, makeRegistrar: { _ in nil })
    ) -> JournalSessionController {
        JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil,
            storageLocationProvider: { .localOnly },
            makeGroupAPI: makeGroupAPI,
            groupNotificationOpener: opener,
            attachesGroupSubscription: false
        )
    }

    func testFlagOffBuildsNoGroupsController() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-groups-off-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root: root, makeGroupAPI: nil)

        await controller.activate(appleUserIdentifier: "apple-user")

        let model = try XCTUnwrap(controller.appModel)
        XCTAssertNil(model.groups, "the sidebar shows the 그룹 section only with a controller")
    }

    func testFlagOnInjectsAGroupsControllerForLocalScopesToo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-groups-on-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = makeController(root: root, makeGroupAPI: { _ in PreviewGroupAPI() })

        await controller.activate(appleUserIdentifier: "apple-user")

        let groups = try XCTUnwrap(controller.appModel?.groups)
        await groups.refresh()
        XCTAssertFalse(groups.groups.isEmpty)
        XCTAssertNil(groups.lastError)
    }

    func testTheClientIsBuiltForTheJournalUsersKeychainAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-groups-account-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        var accounts: [String] = []
        let controller = makeController(
            root: root,
            makeGroupAPI: { account in
                accounts.append(account)
                return PreviewGroupAPI()
            })

        await controller.activate(appleUserIdentifier: "apple-user")

        XCTAssertEqual(accounts, [GroupCredentialStore.account(forAppleUser: "apple-user")])
    }

    func testNotificationTapsGoThroughTheOpenerAndWaitForTheAppLock() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-groups-opener-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = GroupNotificationOpener(isEnabled: true, makeRegistrar: { _ in nil })
        let controller = makeController(
            root: root, makeGroupAPI: { _ in PreviewGroupAPI() }, opener: opener)
        await controller.activate(appleUserIdentifier: "apple-user")
        let model = try XCTUnwrap(controller.appModel)
        let groups = try XCTUnwrap(model.groups)
        await groups.refresh()
        let groupID = try XCTUnwrap(groups.groups.first).id

        groups.onOpenRoute?(.group(groupID))
        XCTAssertEqual(opener.gate.waiting, .group(groupID), "held until the lock is settled")
        XCTAssertNil(model.selectedGroupID)

        opener.attach(model: model) { _ in }
        XCTAssertEqual(opener.gate.waiting, .group(groupID), "still held: lock not read yet")
        opener.updateLock(isLocked: true, isShielded: false)
        XCTAssertEqual(opener.gate.waiting, .group(groupID), "still held: locked")
        opener.updateLock(isLocked: false, isShielded: false)
        XCTAssertNil(opener.gate.waiting)
        await opener.openTask?.value
        XCTAssertEqual(model.selectedGroupID, groupID)
        XCTAssertNil(opener.unavailableMessage)
    }
}

@MainActor
final class GroupsControllerShellTests: XCTestCase {
    func testRefreshLoadsGroupsAndKeepsThemOnFailure() async {
        let groups = GroupsController(
            api: PreviewGroupAPI(),
            invites: PendingGroupInvite(isEnabled: true),
            notifications: GroupNotificationRouting(isEnabled: true))
        await groups.refresh()
        XCTAssertTrue(groups.hasLoaded)
        XCTAssertFalse(groups.groups.isEmpty)
        XCTAssertGreaterThanOrEqual(groups.totalUnreadCount, 0)
        let first = groups.groups[0]
        XCTAssertEqual(groups.group(first.id), first)
    }

    func testSignedOutRefreshReportsTheError() async {
        let groups = GroupsController(
            api: PreviewGroupAPI(seeded: false, signedIn: false),
            invites: PendingGroupInvite(isEnabled: true),
            notifications: GroupNotificationRouting(isEnabled: true))
        await groups.refresh()
        XCTAssertEqual(groups.lastError, .notSignedIn)
        XCTAssertNotNil(groups.errorMessage)
        XCTAssertTrue(groups.groups.isEmpty)
    }

    func testAttachTakesInvitesAndRoutesQueuedBeforeAndAfter() throws {
        let invites = PendingGroupInvite(isEnabled: true)
        let notifications = GroupNotificationRouting(isEnabled: true)
        let groups = GroupsController(
            api: PreviewGroupAPI(), invites: invites, notifications: notifications)
        var opened: [GroupNotificationRoute] = []
        groups.onOpenRoute = { opened.append($0) }
        let early = try XCTUnwrap(InviteCode(normalizing: "AAAA-BBBB-CCCC"))
        invites.add(early)
        let groupID = UUID()
        notifications.receive(.group(groupID))

        groups.attachToSystemEvents()
        XCTAssertEqual(groups.pendingInviteCodes, [early])
        XCTAssertEqual(opened, [.group(groupID)])
        XCTAssertFalse(invites.hasWaiting)
        XCTAssertFalse(notifications.hasWaitingRoutes)

        let late = try XCTUnwrap(InviteCode(normalizing: "DDDDEEEEFFFF"))
        XCTAssertTrue(invites.add(url: late.url()))
        notifications.receive(.dailyReport)
        XCTAssertEqual(groups.pendingInviteCodes, [early, late])
        XCTAssertEqual(opened, [.group(groupID), .dailyReport])

        XCTAssertEqual(groups.takeNextPendingInvite(), early)
        XCTAssertEqual(groups.pendingInviteCodes, [late])
    }
}

@MainActor
final class GroupsInviteQueueTests: XCTestCase {
    private let code = InviteCode(normalizing: "PREV1EW0C0DE")!

    func testInviteLinksAreQueued() {
        let queue = PendingGroupInvite(isEnabled: true)
        var received = 0
        queue.onReceive = { received += 1 }

        XCTAssertTrue(
            queue.add(url: URL(string: "https://pilgrim.delight-house.org/i/prev-1ew0-c0de")!))

        XCTAssertEqual(received, 1)
        XCTAssertEqual(queue.drain(), [code])
        XCTAssertFalse(queue.hasWaiting)
    }

    func testOtherURLsAreLeftAlone() {
        let queue = PendingGroupInvite(isEnabled: true)
        for text in [
            "http://pilgrim.delight-house.org/i/PREV1EW0C0DE",
            "https://example.com/i/PREV1EW0C0DE",
            "https://pilgrim.delight-house.org/admin",
            "https://pilgrim.delight-house.org/i/",
            "https://pilgrim.delight-house.org/i/NOTACODE",
            "https://pilgrim.delight-house.org/x/PREV1EW0C0DE",
            "pilgrim://i/PREV1EW0C0DE",
        ] {
            XCTAssertFalse(queue.add(url: URL(string: text)!), text)
        }
        XCTAssertFalse(queue.hasWaiting)
    }

    func testNothingIsQueuedWhileGroupsAreOff() {
        let queue = PendingGroupInvite(isEnabled: false)
        XCTAssertFalse(queue.add(url: code.url()))
        queue.add(code)
        XCTAssertFalse(queue.hasWaiting)
    }

    func testTheSameLinkArrivingTwiceIsQueuedOnce() {
        var now = Date(timeIntervalSince1970: 1_000)
        let queue = PendingGroupInvite(isEnabled: true, duplicateWindow: 5, now: { now })
        var received = 0
        queue.onReceive = { received += 1 }

        queue.add(url: code.url())
        _ = queue.drain()
        now += 1
        queue.add(url: code.url())
        XCTAssertFalse(queue.hasWaiting, "a second delivery of the same link is dropped")
        XCTAssertEqual(received, 1)

        now += 10
        queue.add(url: code.url())
        XCTAssertEqual(queue.drain(), [code], "opening the link again later counts")
    }

    func testUniversalLinkActivities() {
        let queue = PendingGroupInvite(isEnabled: true)
        let browsing = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        browsing.webpageURL = code.url()
        XCTAssertTrue(queue.add(userActivity: browsing))

        let other = NSUserActivity(activityType: "com.dhouse.PilgrimJournal.other")
        other.webpageURL = code.url()
        XCTAssertFalse(queue.add(userActivity: other))
        XCTAssertEqual(queue.drain(), [code])
    }
}

@MainActor
final class GroupsNotificationRoutingTests: XCTestCase {
    private func userInfo(_ payload: PushPayload) throws -> [AnyHashable: Any] {
        let data = try PilgrimJSON.encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
    }

    func testNewPostOpensThePost() throws {
        let groupID = UUID()
        let postID = UUID()
        let payload = PushPayload.newPost(
            groupID: groupID, postID: postID, kind: .prayer, groupName: "수요 기도모임",
            authorName: "민지")
        XCTAssertEqual(
            GroupNotificationRoute(userInfo: try userInfo(payload)),
            .post(groupID: groupID, postID: postID))
        let answered = PushPayload.prayerAnswered(
            groupID: groupID, postID: postID, groupName: "수요 기도모임", authorName: "민지")
        XCTAssertEqual(
            GroupNotificationRoute(userInfo: try userInfo(answered)),
            .post(groupID: groupID, postID: postID))
    }

    func testGroupEventsAndDailyReport() throws {
        let groupID = UUID()
        for event: PushPayload.GroupEvent in [
            .voteStarted, .voteRunoff, .voteDecided(newAdminName: "민지"), .deletionScheduled,
        ] {
            let payload = PushPayload.group(event, groupID: groupID, groupName: "수요 기도모임")
            XCTAssertEqual(GroupNotificationRoute(userInfo: try userInfo(payload)), .group(groupID))
        }
        XCTAssertEqual(
            GroupNotificationRoute(userInfo: try userInfo(.dailyReport(itemCount: 3))), .dailyReport
        )
    }

    func testUppercaseUUIDsFromAHandWrittenPayloadStillParse() {
        let groupID = UUID()
        let postID = UUID()
        let info: [AnyHashable: Any] = [
            "aps": ["alert": ["loc-key": "GROUP_NEW_POST_PRAYER"]],
            "pilgrim": [
                "v": 1, "kind": "newPost", "groupId": groupID.uuidString,
                "postId": postID.uuidString,
            ],
        ]
        XCTAssertEqual(
            GroupNotificationRoute(userInfo: info), .post(groupID: groupID, postID: postID))
    }

    func testOtherNotificationsAreNotGroupRoutes() {
        XCTAssertNil(GroupNotificationRoute(userInfo: [:]))
        XCTAssertNil(GroupNotificationRoute(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(GroupNotificationRoute(userInfo: ["pilgrim": "newPost"]))
        XCTAssertNil(
            GroupNotificationRoute(userInfo: ["pilgrim": ["v": 1, "kind": "somethingNew"]]))
        XCTAssertNil(
            GroupNotificationRoute(userInfo: ["pilgrim": ["v": 1, "kind": "newPost"]]),
            "a new-post notice needs its group")
        XCTAssertNil(
            GroupNotificationRoute(userInfo: ["pilgrim": ["v": 1, "kind": "voteStarted"]]))
    }

    func testHubQueuesTapsOnlyWhileOn() throws {
        let payload = PushPayload.dailyReport(itemCount: 1)
        let off = GroupNotificationRouting(isEnabled: false)
        XCTAssertFalse(off.handleTap(userInfo: try userInfo(payload)))
        XCTAssertFalse(off.hasWaitingRoutes)

        let on = GroupNotificationRouting(isEnabled: true)
        var signals = 0
        on.onRoute = { signals += 1 }
        XCTAssertFalse(on.handleTap(userInfo: ["aps": [:]]))
        XCTAssertTrue(on.handleTap(userInfo: try userInfo(payload)))
        XCTAssertEqual(signals, 1)
        XCTAssertEqual(on.drainRoutes(), [.dailyReport])
        XCTAssertFalse(on.hasWaitingRoutes)
    }

    func testDeviceTokenIsKeptAndReportedOnce() {
        let hub = GroupNotificationRouting(isEnabled: true)
        var reported: [Data] = []
        hub.onDeviceToken = { reported.append($0) }
        let token = Data([0x0a, 0xff, 0x00, 0x42])

        hub.didFailToRegisterForRemoteNotifications(URLError(.notConnectedToInternet))
        XCTAssertNotNil(hub.registrationFailureDescription)
        hub.didRegisterForRemoteNotifications(deviceToken: token)
        hub.didRegisterForRemoteNotifications(deviceToken: token)

        XCTAssertEqual(hub.deviceToken, token)
        XCTAssertNil(hub.registrationFailureDescription)
        XCTAssertEqual(reported, [token])
        XCTAssertEqual(GroupNotificationRouting.hexString(deviceToken: token), "0aff0042")

        let off = GroupNotificationRouting(isEnabled: false)
        off.didRegisterForRemoteNotifications(deviceToken: token)
        XCTAssertNil(off.deviceToken)
    }
}
#endif
