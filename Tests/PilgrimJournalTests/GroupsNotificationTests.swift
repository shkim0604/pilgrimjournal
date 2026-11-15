#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalGroups
import JournalSearch
import PilgrimAPI
@testable import PilgrimJournal
import SwiftUI
import XCTest

// MARK: - Pure rules

final class GroupNotificationPolicyTests: XCTestCase {
    func testAsksOnlyWhileUndecidedOnceAndWithAGroup() {
        XCTAssertTrue(
            GroupNotificationPermissionPolicy.shouldRequestAuthorization(
                status: .notDetermined, hasAskedOnThisDevice: false, groupCount: 1))
        // Before the first create or join.
        XCTAssertFalse(
            GroupNotificationPermissionPolicy.shouldRequestAuthorization(
                status: .notDetermined, hasAskedOnThisDevice: false, groupCount: 0))
        // Asked before on this installation.
        XCTAssertFalse(
            GroupNotificationPermissionPolicy.shouldRequestAuthorization(
                status: .notDetermined, hasAskedOnThisDevice: true, groupCount: 3))
        for decided in [GroupNotificationAuthorization.denied, .authorized, .provisional] {
            XCTAssertFalse(
                GroupNotificationPermissionPolicy.shouldRequestAuthorization(
                    status: decided, hasAskedOnThisDevice: false, groupCount: 2))
        }
    }

    func testRegistersWithAPNsOnlyWhenAllowedAndInAGroup() {
        XCTAssertTrue(
            GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
                status: .authorized, groupCount: 1))
        XCTAssertTrue(
            GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
                status: .provisional, groupCount: 1))
        XCTAssertFalse(
            GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
                status: .authorized, groupCount: 0))
        XCTAssertFalse(
            GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
                status: .denied, groupCount: 1))
        XCTAssertFalse(
            GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
                status: .notDetermined, groupCount: 1))
    }

    func testTokenDecision() {
        let token = Data([0x0A, 0xFF, 0x00, 0x42])
        XCTAssertEqual(
            GroupDeviceRegistration.tokenDecision(status: .authorized, deviceToken: token),
            .send("0aff0042"))
        // Allowed but APNs has not answered: keep what the server has.
        XCTAssertEqual(
            GroupDeviceRegistration.tokenDecision(status: .authorized, deviceToken: nil), .wait)
        XCTAssertEqual(
            GroupDeviceRegistration.tokenDecision(status: .authorized, deviceToken: Data()), .wait)
        // Not allowed: tell the server not to push here, even with an old token.
        XCTAssertEqual(
            GroupDeviceRegistration.tokenDecision(status: .denied, deviceToken: token), .send(nil))
        XCTAssertEqual(
            GroupDeviceRegistration.tokenDecision(status: .notDetermined, deviceToken: nil),
            .send(nil))
    }

    func testRegistrationBody() throws {
        XCTAssertEqual(GroupDeviceRegistration.apnsEnvironment(isDebugBuild: true), .sandbox)
        XCTAssertEqual(GroupDeviceRegistration.apnsEnvironment(isDebugBuild: false), .production)

        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let request = GroupDeviceRegistration.request(
            apnsToken: "0aff0042", isDebugBuild: false, bundleID: BundleIDs.release,
            platform: .ios, locale: Locale(identifier: "ko_KR"), timeZone: zone,
            appVersion: "1.2.0 (45)")
        XCTAssertEqual(
            request,
            DeviceRegistrationRequest(
                apnsToken: "0aff0042", apnsEnvironment: .production, bundleId: BundleIDs.release,
                platform: .ios, locale: "ko-KR", timeZone: "Asia/Seoul", appVersion: "1.2.0 (45)"))
    }
}

final class GroupNotificationRouteGateTests: XCTestCase {
    private let groupID = UUID()
    private let postID = UUID()

    private var open: GroupNotificationRouteGate.Conditions {
        .init(isLockSettled: true, isLocked: false, isShielded: false, hasDestination: true)
    }

    func testHoldsUntilTheLockHasBeenRead() {
        var gate = GroupNotificationRouteGate()
        XCTAssertNil(gate.receive(.dailyReport))
        var conditions = open
        conditions.isLockSettled = false
        XCTAssertNil(gate.update(conditions))
        XCTAssertEqual(gate.waiting, .dailyReport)
        XCTAssertEqual(gate.update(open), .dailyReport)
        XCTAssertNil(gate.waiting)
    }

    func testHoldsWhileLockedShieldedOrWithoutAWindow() {
        for change in [
            { (c: inout GroupNotificationRouteGate.Conditions) in c.isLocked = true },
            { (c: inout GroupNotificationRouteGate.Conditions) in c.isShielded = true },
            { (c: inout GroupNotificationRouteGate.Conditions) in c.hasDestination = false },
        ] {
            var gate = GroupNotificationRouteGate()
            var conditions = open
            change(&conditions)
            XCTAssertNil(gate.update(conditions))
            XCTAssertNil(gate.receive(.group(groupID)))
            XCTAssertEqual(gate.waiting, .group(groupID))
            XCTAssertEqual(gate.update(open), .group(groupID))
            // Released once.
            XCTAssertNil(gate.update(open))
        }
    }

    func testKeepsOnlyTheNewestWaitingTap() {
        var gate = GroupNotificationRouteGate()
        XCTAssertNil(gate.receive(.group(groupID)))
        XCTAssertNil(gate.receive(.post(groupID: groupID, postID: postID)))
        XCTAssertEqual(gate.update(open), .post(groupID: groupID, postID: postID))
    }

    func testPassesStraightThroughWhenOpen() {
        var gate = GroupNotificationRouteGate()
        XCTAssertNil(gate.update(open))
        XCTAssertEqual(gate.receive(.dailyReport), .dailyReport)
        XCTAssertNil(gate.waiting)
    }

    func testDiscard() {
        var gate = GroupNotificationRouteGate()
        _ = gate.receive(.dailyReport)
        gate.discardWaiting()
        XCTAssertNil(gate.update(open))
    }
}

final class GroupNotificationDestinationTests: XCTestCase {
    func testResolve() {
        let member = UUID()
        let gone = UUID()
        let post = UUID()
        let members: Set<UUID> = [member]

        XCTAssertEqual(
            GroupNotificationDestination.resolve(.dailyReport, memberGroupIDs: []), .dailyReport)
        XCTAssertEqual(
            GroupNotificationDestination.resolve(.group(member), memberGroupIDs: members),
            .group(member))
        XCTAssertEqual(
            GroupNotificationDestination.resolve(
                .post(groupID: member, postID: post), memberGroupIDs: members),
            .post(groupID: member, postID: post))
        XCTAssertEqual(
            GroupNotificationDestination.resolve(.group(gone), memberGroupIDs: members),
            .unavailable("이 그룹은 더 이상 볼 수 없어요"))
        XCTAssertEqual(
            GroupNotificationDestination.resolve(
                .post(groupID: gone, postID: post), memberGroupIDs: members),
            .unavailable("이 글은 더 이상 볼 수 없어요"))
        // The list is unknown (offline): open and let the screen show what the server says.
        XCTAssertEqual(
            GroupNotificationDestination.resolve(.group(gone), memberGroupIDs: nil), .group(gone))
    }

    func testCompactColumn() {
        XCTAssertEqual(GroupNotificationDestination.group(UUID()).compactColumn, .content)
        XCTAssertEqual(
            GroupNotificationDestination.post(groupID: UUID(), postID: UUID()).compactColumn,
            .detail)
        XCTAssertNil(GroupNotificationDestination.dailyReport.compactColumn)
        XCTAssertNil(GroupNotificationDestination.unavailable("x").compactColumn)
    }
}

// MARK: - Registrar

@MainActor
final class FakeGroupNotificationCenter: GroupNotificationCenter {
    var status: GroupNotificationAuthorization
    var answer: Bool
    private(set) var requestCount = 0
    private(set) var apnsRegistrationCount = 0

    init(status: GroupNotificationAuthorization = .notDetermined, answer: Bool = true) {
        self.status = status
        self.answer = answer
    }

    func authorizationStatus() async -> GroupNotificationAuthorization { status }

    func requestAuthorization() async -> Bool {
        requestCount += 1
        status = answer ? .authorized : .denied
        return answer
    }

    func registerForRemoteNotifications() {
        apnsRegistrationCount += 1
    }
}

@MainActor
final class GroupNotificationRegistrarTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "group-notifications-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func make(
        center: FakeGroupNotificationCenter, routing: GroupNotificationRouting,
        signedIn: Bool = true
    ) async -> (GroupNotificationRegistrar, ScriptedGroupAPI, GroupsController) {
        let api = ScriptedGroupAPI(base: PreviewGroupAPI(signedIn: signedIn))
        let groups = GroupsMembershipFixtures.controller(api: api)
        await groups.start()
        let registrar = GroupNotificationRegistrar(
            groups: groups, isEnabled: true, center: center, routing: routing,
            credentials: InMemoryGroupSecureItemStore(), defaults: defaults,
            bundleID: BundleIDs.debug, isDebugBuild: true, appVersion: "1.2.0 (1)",
            locale: { Locale(identifier: "ko_KR") },
            timeZone: { TimeZone(identifier: "Asia/Seoul")! }, promptDelay: .zero)
        return (registrar, api, groups)
    }

    private func registrations(_ api: ScriptedGroupAPI) async -> Int {
        await api.calls.filter { $0.hasPrefix("registerDevice") }.count
    }

    func testFirstMembershipAsksOnceThenRegistersWithTheToken() async throws {
        let center = FakeGroupNotificationCenter()
        let routing = GroupNotificationRouting(isEnabled: true)
        let (registrar, api, groups) = await make(center: center, routing: routing)
        XCTAssertFalse(groups.groups.isEmpty)

        await registrar.sync()
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertTrue(registrar.hasAskedOnThisDevice)
        XCTAssertEqual(registrar.authorization, .authorized)
        XCTAssertEqual(center.apnsRegistrationCount, 1)
        // No token yet: nothing sent, so the server keeps any token it has.
        let beforeToken = await registrations(api)
        XCTAssertEqual(beforeToken, 0)

        routing.didRegisterForRemoteNotifications(deviceToken: Data([0xAB, 0xCD, 0x01, 0x02]))
        await registrar.sync()
        let afterToken = await registrations(api)
        XCTAssertEqual(afterToken, 1)
        XCTAssertEqual(registrar.lastRegistration?.apnsToken, "abcd0102")
        XCTAssertEqual(registrar.lastRegistration?.apnsEnvironment, .sandbox)
        XCTAssertEqual(registrar.lastRegistration?.bundleId, BundleIDs.debug)
        XCTAssertEqual(registrar.lastRegistration?.timeZone, "Asia/Seoul")

        // Nothing changed: no second prompt, no APNs call, no repeated PUT.
        await registrar.sync()
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(center.apnsRegistrationCount, 1)
        let unchanged = await registrations(api)
        XCTAssertEqual(unchanged, 1)
    }

    func testDeniedRegistersWithoutAToken() async throws {
        let center = FakeGroupNotificationCenter(answer: false)
        let routing = GroupNotificationRouting(isEnabled: true)
        let (registrar, api, groups) = await make(center: center, routing: routing)

        await registrar.sync()
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(center.apnsRegistrationCount, 0)
        let count = await registrations(api)
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(registrar.lastRegistration)
        XCTAssertNil(registrar.lastRegistration?.apnsToken)
        withExtendedLifetime(groups) {}
    }

    func testNeverAsksAgainOnThisInstallation() async throws {
        defaults.set(true, forKey: GroupNotificationRegistrar.askedDefaultsKey)
        let center = FakeGroupNotificationCenter()
        let (registrar, _, groups) = await make(
            center: center, routing: GroupNotificationRouting(isEnabled: true))
        await registrar.sync()
        XCTAssertEqual(center.requestCount, 0)
        XCTAssertEqual(registrar.authorization, .notDetermined)
        withExtendedLifetime(groups) {}
    }

    func testSignedOutDoesNothing() async throws {
        let center = FakeGroupNotificationCenter()
        let (registrar, api, groups) = await make(
            center: center, routing: GroupNotificationRouting(isEnabled: true), signedIn: false)
        XCTAssertFalse(groups.accountState.hasGroupAccess)
        await registrar.sync()
        XCTAssertEqual(center.requestCount, 0)
        let count = await registrations(api)
        XCTAssertEqual(count, 0)
    }

    func testOffDoesNothing() async throws {
        let center = FakeGroupNotificationCenter()
        let api = ScriptedGroupAPI(base: PreviewGroupAPI())
        let groups = GroupsMembershipFixtures.controller(api: api)
        await groups.start()
        let registrar = GroupNotificationRegistrar(
            groups: groups, isEnabled: false, center: center,
            routing: GroupNotificationRouting(isEnabled: true),
            credentials: InMemoryGroupSecureItemStore(), defaults: defaults, promptDelay: .zero)
        registrar.start()
        await registrar.sync()
        await registrar.waitUntilIdle()
        XCTAssertEqual(center.requestCount, 0)
    }

    func testStartFollowsTheTokenCallback() async throws {
        let center = FakeGroupNotificationCenter(status: .authorized)
        let routing = GroupNotificationRouting(isEnabled: true)
        let (registrar, api, groups) = await make(center: center, routing: routing)
        registrar.start()
        await registrar.waitUntilIdle()
        XCTAssertEqual(center.apnsRegistrationCount, 1)

        routing.didRegisterForRemoteNotifications(deviceToken: Data([0x01, 0x02, 0x03, 0x04]))
        await registrar.waitUntilIdle()
        let count = await registrations(api)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(registrar.lastRegistration?.apnsToken, "01020304")
        registrar.stop()
        withExtendedLifetime(groups) {}
    }
}

// MARK: - Opener

@MainActor
final class GroupNotificationOpenerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-group-opener-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() async throws -> AppModel {
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(url: paths.search.appending(path: "opener.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: UserDefaults(suiteName: "opener-\(UUID().uuidString)")!
        )
        let groups = GroupsMembershipFixtures.controller(api: PreviewGroupAPI())
        await groups.start()
        model.groups = groups
        return model
    }

    private func makeOpener() -> GroupNotificationOpener {
        GroupNotificationOpener(isEnabled: true, makeRegistrar: { _ in nil })
    }

    func testWaitsForTheUnlockedJournalThenOpensThePost() async throws {
        let model = try await makeModel()
        let groupID = try XCTUnwrap(model.groups?.groups.first?.id)
        let postID = UUID()
        let opener = makeOpener()
        var columns: [NavigationSplitViewColumn] = []

        opener.receive(.post(groupID: groupID, postID: postID))
        opener.attach(model: model) { columns.append($0) }
        XCTAssertNil(opener.openTask, "the app lock has not been read yet")

        opener.updateLock(isLocked: true, isShielded: false)
        XCTAssertNil(opener.openTask)
        XCTAssertNil(model.selectedGroupID)

        opener.updateLock(isLocked: false, isShielded: false)
        await opener.openTask?.value
        XCTAssertEqual(model.selectedGroupID, groupID)
        XCTAssertEqual(model.selectedGroupPostID, postID)
        XCTAssertEqual(columns, [.detail])
    }

    func testAGroupThatIsNoLongerMineShowsAMessage() async throws {
        let model = try await makeModel()
        let opener = makeOpener()
        opener.attach(model: model) { _ in }
        opener.updateLock(isLocked: false, isShielded: false)

        opener.receive(.post(groupID: UUID(), postID: UUID()))
        await opener.openTask?.value
        XCTAssertEqual(opener.unavailableMessage, "이 글은 더 이상 볼 수 없어요")
        XCTAssertNil(model.selectedGroupID)

        opener.unavailableMessage = nil
        opener.receive(.group(UUID()))
        await opener.openTask?.value
        XCTAssertEqual(opener.unavailableMessage, "이 그룹은 더 이상 볼 수 없어요")
    }

    func testDailyReportOpensTheSheetAndAPostClosesIt() async throws {
        let model = try await makeModel()
        let groupID = try XCTUnwrap(model.groups?.groups.first?.id)
        let opener = makeOpener()
        opener.attach(model: model) { _ in }
        opener.updateLock(isLocked: false, isShielded: false)

        opener.receive(.dailyReport)
        await opener.openTask?.value
        XCTAssertTrue(opener.isPresentingDailyReport)

        await opener.open(.group(groupID))
        XCTAssertFalse(opener.isPresentingDailyReport)
        XCTAssertEqual(model.selectedGroupID, groupID)
    }

    func testDetachedWindowHoldsTheTap() async throws {
        let model = try await makeModel()
        let groupID = try XCTUnwrap(model.groups?.groups.first?.id)
        let opener = makeOpener()
        opener.updateLock(isLocked: false, isShielded: false)
        opener.attach(model: model) { _ in }
        opener.detach(model: model)

        opener.receive(.group(groupID))
        XCTAssertNil(opener.openTask)
        opener.attach(model: model) { _ in }
        await opener.openTask?.value
        XCTAssertEqual(model.selectedGroupID, groupID)
    }

    func testOffIgnoresTaps() async throws {
        let model = try await makeModel()
        let opener = GroupNotificationOpener(isEnabled: false, makeRegistrar: { _ in nil })
        opener.attach(model: model) { _ in }
        opener.updateLock(isLocked: false, isShielded: false)
        opener.receive(.dailyReport)
        XCTAssertNil(opener.openTask)
        XCTAssertFalse(opener.isPresentingDailyReport)
    }
}

// MARK: - Daily Report

final class DailyReportPresentationTests: XCTestCase {
    private let author = UserSummary(id: UUID(), displayName: "민지")

    private func post(_ title: String, kind: PostKind = .prayer, count: Int = 1) -> DailyReportPost
    {
        DailyReportPost(
            postId: UUID(), kind: kind, title: title, author: author, count: count,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSectionsKeepTheServerContentInAFixedOrderAndSkipEmptyParts() {
        let group = DailyReportGroup(
            groupId: UUID(), groupName: "수요 기도모임",
            newPosts: [post("새 기도제목")],
            reactionsOnMyPosts: [post("내 간증", kind: .testimony, count: 4)],
            expiringSoon: [post("곧 사라짐")])
        XCTAssertEqual(
            DailyReportPresentation.sections(for: group).map(\.kind),
            [.newPosts, .reactionsOnMyPosts, .expiringSoon])
        XCTAssertEqual(
            DailyReportPresentation.sections(
                for: DailyReportGroup(groupId: UUID(), groupName: "빈 그룹")), [])
    }

    func testOnlyGroupsWithNewsAreShown() {
        let busy = DailyReportGroup(groupId: UUID(), groupName: "A", newPosts: [post("x")])
        let quiet = DailyReportGroup(groupId: UUID(), groupName: "B")
        let report = DailyReportResponse(
            date: LocalDate(year: 2026, month: 11, day: 14)!, windowStart: Date(),
            windowEnd: Date(), totalCount: 1, groups: [quiet, busy])
        XCTAssertEqual(DailyReportPresentation.groups(in: report).map(\.groupName), ["A"])
    }

    func testRowText() {
        let now = Date(timeIntervalSince1970: 1_799_990_000)
        XCTAssertEqual(
            DailyReportPresentation.detail(for: post("x"), in: .newPosts, now: now),
            "민지 · 기도제목")
        XCTAssertEqual(
            DailyReportPresentation.detail(
                for: post("x", count: 3), in: .commentsOnMyPosts, now: now),
            "댓글 3개")
        XCTAssertEqual(
            DailyReportPresentation.detail(
                for: post("x", count: 5), in: .reactionsOnMyPosts, now: now),
            "반응 5개")
        XCTAssertEqual(
            DailyReportPresentation.detail(for: post("x"), in: .expiringSoon, now: now),
            "민지 · 2시간 뒤 사라져요")
        XCTAssertEqual(DailyReportPresentation.title(for: post("  ")), "제목 없음")
        XCTAssertEqual(DailyReportPresentation.title(for: post(" 감사 ")), "감사")
    }

    func testLocalTimeAndPickerDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let time = try XCTUnwrap(LocalTime(hour: 21, minute: 30))
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let date = time.date(on: day, calendar: calendar)
        XCTAssertEqual(LocalTime(date: date, calendar: calendar), time)
        XCTAssertEqual(calendar.component(.hour, from: date), 21)
        XCTAssertTrue(calendar.isDate(date, inSameDayAs: day))
    }

    func testTimeZoneDifference() throws {
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        XCTAssertFalse(DailyReportTimeZone.differs(server: "Asia/Seoul", device: seoul))
        XCTAssertTrue(DailyReportTimeZone.differs(server: "America/New_York", device: seoul))
        XCTAssertFalse(DailyReportTimeZone.differs(server: nil, device: seoul))
        XCTAssertFalse(DailyReportTimeZone.differs(server: "Not/AZone", device: seoul))
    }
}

@MainActor
final class DailyReportModelTests: XCTestCase {
    private let latest = LocalDate(year: 2026, month: 11, day: 14)!

    private func report(_ date: LocalDate) -> DailyReportResponse {
        DailyReportResponse(
            date: date, windowStart: Date(), windowEnd: Date(), totalCount: 0, groups: [])
    }

    func testLoadsTheLatestThenMovesBetweenDays() async {
        var requested: [LocalDate?] = []
        let model = DailyReportModel(fetch: { [latest] date in
            requested.append(date)
            return self.report(date ?? latest)
        })
        await model.load()
        XCTAssertEqual(model.date, latest)
        XCTAssertEqual(model.latestDate, latest)
        XCTAssertFalse(model.canShowNextDay)
        XCTAssertTrue(model.canShowPreviousDay)

        await model.showPreviousDay()
        XCTAssertEqual(model.date, latest.adding(days: -1))
        XCTAssertTrue(model.canShowNextDay)
        await model.load()
        XCTAssertEqual(model.date, latest.adding(days: -1), "a refresh stays on the day")

        await model.showNextDay()
        XCTAssertEqual(model.date, latest)
        XCTAssertEqual(
            requested, [nil, latest.adding(days: -1), latest.adding(days: -1), latest])
    }

    func testGoesBackAtMostAWeek() async {
        let model = DailyReportModel(fetch: { [latest] date in self.report(date ?? latest) })
        await model.load()
        for _ in 0..<20 { await model.showPreviousDay() }
        XCTAssertEqual(model.date, latest.adding(days: -DailyReportModel.maximumDaysBack))
        XCTAssertFalse(model.canShowPreviousDay)
    }

    func testFailureShowsTheMessageAndReportsTheError() async {
        var reported: [GroupAPIError] = []
        let model = DailyReportModel(
            fetch: { _ in throw GroupAPIError.offline },
            onError: { reported.append(GroupsController.normalize($0)) })
        await model.load()
        XCTAssertEqual(model.state, .failed(GroupContentError.offlineMessage))
        XCTAssertEqual(reported, [.offline])
    }

    func testPreviewServerReport() async throws {
        let groups = GroupsMembershipFixtures.controller(api: PreviewGroupAPI())
        let model = DailyReportModel(groups: groups)
        await model.load()
        XCTAssertNotNil(model.report)
    }
}

@MainActor
final class GroupReportSettingsModelTests: XCTestCase {
    private func me(
        enabled: Bool = true, time: LocalTime = .defaultDailyReport, zone: String = "Asia/Seoul"
    )
        -> MeResponse
    {
        MeResponse(
            id: UUID(), displayName: "나", profileComplete: true, timeZone: zone,
            dailyReportEnabled: enabled, dailyReportTime: time, createdAt: Date(),
            entitlement: .notRequired)
    }

    func testSavesTheSwitchAndPutsItBackOnFailure() async {
        var sent: [UpdateMeRequest] = []
        var failure: GroupAPIError?
        var refreshed = 0
        let model = GroupReportSettingsModel(
            update: { request in
                sent.append(request)
                if let failure { throw failure }
                return self.me(enabled: request.dailyReportEnabled ?? true)
            },
            didUpdate: { refreshed += 1 }, debounce: .zero)
        model.sync(from: me())
        XCTAssertTrue(model.hasProfile)
        XCTAssertTrue(model.isEnabled)

        await model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(sent, [UpdateMeRequest(dailyReportEnabled: false)])
        XCTAssertEqual(refreshed, 1)
        XCTAssertNil(model.errorMessage)

        failure = .offline
        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled, "put back")
        XCTAssertEqual(model.errorMessage, GroupMessages.offline)
        XCTAssertEqual(refreshed, 1)
    }

    func testPickedTimeIsSavedOnceAfterThePickerSettles() async throws {
        var sent: [UpdateMeRequest] = []
        let model = GroupReportSettingsModel(
            update: { request in
                sent.append(request)
                return self.me(time: request.dailyReportTime ?? .defaultDailyReport)
            }, debounce: .milliseconds(50))
        model.sync(from: me())
        let first = try XCTUnwrap(LocalTime(hour: 21, minute: 0))
        let second = try XCTUnwrap(LocalTime(hour: 21, minute: 30))
        model.setTime(first)
        model.setTime(second)
        XCTAssertEqual(model.time, second)
        // A server answer arriving meanwhile does not undo the pick.
        model.sync(from: me())
        XCTAssertEqual(model.time, second)
        await model.waitForPendingTime()
        XCTAssertEqual(sent, [UpdateMeRequest(dailyReportTime: second)])
        XCTAssertEqual(model.time, second)
    }

    func testFailedTimeGoesBackToTheSavedOne() async throws {
        let model = GroupReportSettingsModel(
            update: { _ in throw GroupAPIError.offline }, debounce: .zero)
        model.sync(from: me())
        model.setTime(try XCTUnwrap(LocalTime(hour: 6, minute: 0)))
        await model.waitForPendingTime()
        XCTAssertEqual(model.time, .defaultDailyReport)
        XCTAssertNotNil(model.errorMessage)
    }

    func testUsesTheDeviceTimeZone() async throws {
        var sent: [UpdateMeRequest] = []
        let model = GroupReportSettingsModel(
            update: { request in
                sent.append(request)
                return self.me(zone: request.timeZone ?? "Asia/Seoul")
            }, debounce: .zero)
        model.sync(from: me(zone: "America/New_York"))
        XCTAssertEqual(model.serverTimeZone, "America/New_York")
        await model.useDeviceTimeZone(try XCTUnwrap(TimeZone(identifier: "Asia/Seoul")))
        XCTAssertEqual(sent, [UpdateMeRequest(timeZone: "Asia/Seoul")])
        XCTAssertEqual(model.serverTimeZone, "Asia/Seoul")
    }

    func testPermissionButtonAsksAndTellsTheRegistrar() async {
        let suite = "report-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = FakeGroupNotificationCenter()
        var changed = 0
        let model = GroupReportSettingsModel(
            update: { _ in self.me() }, center: center, defaults: defaults,
            permissionDidChange: { changed += 1 }, debounce: .zero)
        await model.refreshAuthorization()
        XCTAssertEqual(model.authorization, .notDetermined)
        await model.requestAuthorization()
        XCTAssertEqual(model.authorization, .authorized)
        XCTAssertEqual(center.requestCount, 1)
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(defaults.bool(forKey: GroupNotificationRegistrar.askedDefaultsKey))
    }

    func testNoProfileHidesTheControls() {
        let model = GroupReportSettingsModel(update: { _ in self.me() })
        model.sync(from: nil)
        XCTAssertFalse(model.hasProfile)
    }
}
#endif
