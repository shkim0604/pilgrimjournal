import Fluent
import Foundation
import NIOConcurrencyHelpers
import PilgrimAPI
import SQLKit
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Shared setup for the Postgres-backed subscription tests: a test PKI in place of Apple's root.
class SubscriptionDatabaseTestCase: DatabaseTestCase {
    var pki: AppStoreTestPKI!
    var subscriptionRequired: Bool { false }

    override func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        var config = AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot)
        config.subscriptionRequired = subscriptionRequired
        return config
    }

    override func setUp() async throws {
        try await super.setUp()
        pki = try AppStoreTestPKI()
        app.subscriptionServices.verifier = pki.verifier
    }

    func subscriptionVerify(
        _ payload: [String: Any], as user: User, bundleID: String = BundleIDs.release
    ) async throws -> XCTHTTPResponse {
        try await send(
            .POST, "/api/v1/subscriptions/verify", as: user,
            json: VerifySubscriptionRequest(
                signedTransaction: try pki.sign(payload), bundleId: bundleID))
    }

    func subscriptionNotify(_ payload: [String: Any]) async throws -> XCTHTTPResponse {
        try await send(
            .POST, "/api/appstore/notifications",
            json: AppStoreNotificationRequest(signedPayload: try pki.sign(payload)))
    }

    func subscriptionNotify(
        type: String, subtype: String? = nil, transaction: [String: Any],
        renewal: [String: Any]? = nil, uuid: UUID = UUID(), signed: Date = Date()
    ) async throws -> XCTHTTPResponse {
        try await subscriptionNotify(
            AppStoreTestPayloads.notification(
                type: type, subtype: subtype, uuid: uuid,
                signedTransaction: try pki.sign(transaction),
                signedRenewal: try renewal.map { try pki.sign($0) }, signed: signed))
    }

    func subscriptionRow(_ originalTransactionID: String = "2000000000000001") async throws
        -> AppStoreSubscription?
    {
        try await AppStoreSubscription.query(on: db)
            .filter(\.$originalTransactionID == originalTransactionID)
            .first()
    }

    func subscriptionEntitlement(_ user: User) async throws -> EntitlementResponse {
        let response = try await send(.GET, "/api/v1/me/entitlement", as: user)
        XCTAssertEqual(response.status, .ok, response.body.string)
        return try decode(EntitlementResponse.self, from: response)
    }

    func subscriptionNotificationCount() async throws -> Int {
        try await AppStoreNotification.query(on: db).count()
    }

    /// `/me`, `/me/entitlement`, `SubscriptionEntitlement`, the group gate and the invite
    /// preview must give one answer; all of them now ask `SubscriptionEntitlement`.
    func assertEntitlementAgreesEverywhere(
        _ user: User, expected: EntitlementResponse, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let userID = try user.requireID()
        let config = app.pilgrimConfig
        let me = try await MeResponseBuilder.response(for: user, on: db, config: config)
        let direct = try await SubscriptionEntitlement.response(
            for: userID, subscriptionRequired: config.subscriptionRequired, on: db)
        for (name, actual) in [("GET /me", me.entitlement), ("SubscriptionEntitlement", direct)] {
            XCTAssertEqual(
                actual.subscriptionRequired, expected.subscriptionRequired, name, file: file,
                line: line)
            XCTAssertEqual(actual.active, expected.active, name, file: file, line: line)
            XCTAssertEqual(actual.status, expected.status, name, file: file, line: line)
            XCTAssertEqual(actual.productId, expected.productId, name, file: file, line: line)
            XCTAssertEqual(
                actual.expiresAt?.timeIntervalSince1970 ?? 0,
                expected.expiresAt?.timeIntervalSince1970 ?? 0, accuracy: 0.002, name,
                file: file, line: line)
        }
        var paid = true
        if config.subscriptionRequired {
            paid = SubscriptionEntitlement.hasActiveSubscription(
                try await SubscriptionEntitlement.rows(for: userID, on: db), now: Date())
        }
        XCTAssertEqual(paid, expected.active, "hasActiveSubscription", file: file, line: line)
        // The group gate (`AccountStateMiddleware(requiresSubscription:)`) and media uploads.
        let entitled = try await SubscriptionEntitlement.isEntitled(
            userID, subscriptionRequired: config.subscriptionRequired, on: db)
        XCTAssertEqual(entitled, expected.active, "isEntitled", file: file, line: line)
        // `InviteService.preview`.
        let preview = try await SubscriptionEntitlement.requiresSubscription(
            userID, subscriptionRequired: config.subscriptionRequired, on: db)
        XCTAssertEqual(preview, !expected.active, "invite preview", file: file, line: line)
    }
}

/// `SUBSCRIPTION_REQUIRED=false` — the release state (2.3.1–2.3.3).
final class SubscriptionDatabaseTests: SubscriptionDatabaseTestCase {
    private let later = Date().addingTimeInterval(30 * 86_400)

    // MARK: - Verify

    func testVerifyStoresTheSubscriptionAndAnswersTheEntitlement() async throws {
        let user = try await fixtures.user()
        let userID = try user.requireID()
        let response = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later, appAccountToken: userID), as: user)
        XCTAssertEqual(response.status, .ok, response.body.string)
        let entitlement = try decode(EntitlementResponse.self, from: response)
        XCTAssertFalse(entitlement.subscriptionRequired)
        XCTAssertTrue(entitlement.active)
        XCTAssertEqual(entitlement.status, .active)
        XCTAssertEqual(entitlement.productId, SubscriptionProduct.groupsMonthly)

        let row = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(row.$user.id, userID)
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.environment, .sandbox)
        XCTAssertEqual(row.bundleID, BundleIDs.release)
        XCTAssertEqual(row.appAccountToken, userID)
        XCTAssertEqual(row.lastTransactionID, "2000000000000001")
        XCTAssertEqual(row.storefront, "KOR")
        XCTAssertNil(row.removalProcessedAt)

        // Sent again at the next launch: still one row.
        let again = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later, appAccountToken: userID), as: user)
        XCTAssertEqual(again.status, .ok)
        expectEqual(try await AppStoreSubscription.query(on: db).count(), 1)
    }

    func testVerifyWorksBeforeSignUpAndWithoutAppAccountToken() async throws {
        let user = try await fixtures.user(nil)
        let response = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(bundleID: BundleIDs.debug, expires: later), as: user,
            bundleID: BundleIDs.debug)
        XCTAssertEqual(response.status, .ok, response.body.string)
        expectEqual(try await subscriptionRow()?.$user.id, try user.requireID())
    }

    func testVerifyRefusesAnotherUsersPurchase() async throws {
        let user = try await fixtures.user()
        let other = try await fixtures.user()
        let response = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(
                expires: later, appAccountToken: try other.requireID()), as: user)
        try assertError(response, .subscriptionOwnedByOtherUser)
        expectNil(try await subscriptionRow())
    }

    func testVerifyRefusesATransactionBoundToAnotherUser() async throws {
        let owner = try await fixtures.user()
        let other = try await fixtures.user()
        let first = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later), as: owner)
        XCTAssertEqual(first.status, .ok)
        // Same Apple ID, another Pilgrim account on the device.
        let second = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later), as: other)
        try assertError(second, .subscriptionOwnedByOtherUser)
        expectEqual(try await subscriptionRow()?.$user.id, try owner.requireID())
    }

    func testVerifyLetsANewAccountClaimADeletedAccountsPurchase() async throws {
        // Deleted and signed up again while the App Store subscription keeps renewing: the
        // purchase still carries the old account's ID as its `appAccountToken`.
        let old = try await fixtures.user()
        let oldID = try old.requireID()
        let first = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later, appAccountToken: oldID), as: old)
        XCTAssertEqual(first.status, .ok, first.body.string)
        try await sql.raw("DELETE FROM users WHERE id = \(bind: oldID)").run()

        let fresh = try await fixtures.user()
        let response = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later, appAccountToken: oldID), as: fresh)
        XCTAssertEqual(response.status, .ok, response.body.string)
        XCTAssertTrue(try decode(EntitlementResponse.self, from: response).active)
        expectEqual(try await subscriptionRow()?.$user.id, try fresh.requireID())
    }

    func testVerifyRefusesInvalidData() async throws {
        let user = try await fixtures.user()
        let garbage = try await send(
            .POST, "/api/v1/subscriptions/verify", as: user,
            json: VerifySubscriptionRequest(signedTransaction: "x.y.z", bundleId: BundleIDs.release)
        )
        try assertError(garbage, .subscriptionInvalid)

        let stranger = try AppStoreTestPKI()
        let forged = try await send(
            .POST, "/api/v1/subscriptions/verify", as: user,
            json: VerifySubscriptionRequest(
                signedTransaction: try stranger.sign(
                    AppStoreTestPayloads.transaction(expires: later)),
                bundleId: BundleIDs.release))
        try assertError(forged, .subscriptionInvalid)

        let wrongBundle = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later), as: user, bundleID: BundleIDs.debug)
        try assertError(wrongBundle, .subscriptionInvalid)

        let otherProduct = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(productID: "com.dhouse.other", expires: later),
            as: user)
        try assertError(otherProduct, .subscriptionInvalid)
        expectNil(try await subscriptionRow())
    }

    func testVerifyIsRefusedWhileSuspended() async throws {
        let user = try await fixtures.user()
        user.suspendedAt = Date()
        try await user.save(on: db)
        let response = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: later), as: user)
        try assertError(response, .accountSuspended)
        // Reading the entitlement still works, like GET /me.
        _ = try await subscriptionEntitlement(user)
    }

    // MARK: - Entitlement

    func testEntitlementWhileNotRequired() async throws {
        let user = try await fixtures.user()
        expectEqual(try await subscriptionEntitlement(user), .notRequired)

        // A lapsed purchase is reported, yet the user still counts as subscribed.
        _ = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: Date().addingTimeInterval(-86_400)),
            as: user)
        let entitlement = try await subscriptionEntitlement(user)
        XCTAssertEqual(entitlement.status, .expired)
        XCTAssertTrue(entitlement.active)
        XCTAssertFalse(entitlement.subscriptionRequired)
        try await assertEntitlementAgreesEverywhere(user, expected: entitlement)
    }

    // MARK: - Notifications

    func testNotificationCreatesTheRowForTheAppAccountTokenUser() async throws {
        let user = try await fixtures.user()
        let response = try await subscriptionNotify(
            type: "SUBSCRIBED", subtype: "INITIAL_BUY",
            transaction: AppStoreTestPayloads.transaction(
                expires: later, appAccountToken: try user.requireID()))
        XCTAssertEqual(response.status, .ok, response.body.string)
        let row = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(row.$user.id, try user.requireID())
        XCTAssertEqual(row.status, .active)
        expectEqual(try await subscriptionNotificationCount(), 1)
    }

    func testNotificationForAnUnknownAccountIsKeptUnowned() async throws {
        let response = try await subscriptionNotify(
            type: "SUBSCRIBED",
            transaction: AppStoreTestPayloads.transaction(expires: later, appAccountToken: UUID()))
        XCTAssertEqual(response.status, .ok)
        expectNil(try await subscriptionRow()?.$user.id)
    }

    func testDuplicateNotificationIsAppliedOnce() async throws {
        let user = try await fixtures.user()
        let uuid = UUID()
        let transaction = AppStoreTestPayloads.transaction(
            expires: later, appAccountToken: try user.requireID())
        _ = try await subscriptionNotify(type: "SUBSCRIBED", transaction: transaction, uuid: uuid)
        // The user cancels and gets refunded; then Apple retries the first notification.
        _ = try await subscriptionNotify(
            type: "REFUND", transaction: transaction, signed: Date().addingTimeInterval(60))
        let retried = try await subscriptionNotify(
            type: "SUBSCRIBED", transaction: transaction, uuid: uuid)
        XCTAssertEqual(retried.status, .ok)
        expectEqual(try await subscriptionRow()?.status, .revoked)
        expectEqual(try await subscriptionNotificationCount(), 2)
    }

    func testOlderNotificationDoesNotUndoANewerOne() async throws {
        let user = try await fixtures.user()
        let transaction = AppStoreTestPayloads.transaction(
            expires: later, appAccountToken: try user.requireID())
        let now = Date()
        _ = try await subscriptionNotify(
            type: "DID_RENEW", transaction: transaction, signed: now)
        let late = try await subscriptionNotify(
            type: "EXPIRED", transaction: transaction, signed: now.addingTimeInterval(-3_600))
        XCTAssertEqual(late.status, .ok)
        expectEqual(try await subscriptionRow()?.status, .active)
        expectEqual(try await subscriptionNotificationCount(), 2)
    }

    func testGracePeriodKeepsTheEntitlementUntilItsEnd() async throws {
        let user = try await fixtures.user()
        let lapsed = Date().addingTimeInterval(-3_600)
        let graceEnds = Date().addingTimeInterval(6 * 86_400)
        _ = try await subscriptionNotify(
            type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD",
            transaction: AppStoreTestPayloads.transaction(
                expires: lapsed, appAccountToken: try user.requireID()),
            renewal: AppStoreTestPayloads.renewal(graceEnds: graceEnds))
        let row = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(row.status, .gracePeriod)
        XCTAssertEqual(
            try XCTUnwrap(row.expiresAt).timeIntervalSince1970, graceEnds.timeIntervalSince1970,
            accuracy: 0.01)
        let entitlement = try await subscriptionEntitlement(user)
        XCTAssertEqual(entitlement.status, .gracePeriod)
    }

    func testTestNotificationIsOnlyRecorded() async throws {
        let response = try await subscriptionNotify(AppStoreTestPayloads.notification(type: "TEST"))
        XCTAssertEqual(response.status, .ok)
        expectEqual(try await subscriptionNotificationCount(), 1)
        expectEqual(try await AppStoreSubscription.query(on: db).count(), 0)
    }

    func testUnverifiedNotificationChangesNothing() async throws {
        let stranger = try AppStoreTestPKI()
        let response = try await send(
            .POST, "/api/appstore/notifications",
            json: AppStoreNotificationRequest(
                signedPayload: try stranger.sign(AppStoreTestPayloads.notification(type: "TEST"))))
        try assertError(response, .invalidRequest)
        expectEqual(try await subscriptionNotificationCount(), 0)
    }

    func testExpiryWhileNotRequiredOnlyChangesTheStatus() async throws {
        // Spec "플래그가 꺼진 상태의 만료".
        let member = try await fixtures.user()
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let post = try await fixtures.post(by: member, in: group)
        _ = try await subscriptionNotify(
            type: "EXPIRED", subtype: "VOLUNTARY",
            transaction: AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(-60),
                appAccountToken: try member.requireID()))
        expectEqual(try await subscriptionRow()?.status, .expired)

        let job = SubscriptionWorker.job()
        let result = await WorkerRunner(application: app).runOnce(job)
        XCTAssertEqual(result, .ran)
        expectNotNil(
            try await ContentVisibility.membership(
                of: try member.requireID(), in: try group.requireID(), on: db))
        expectNotNil(try await Post.find(try post.requireID(), on: db))
        expectNil(try await subscriptionRow()?.removalProcessedAt)
    }

    // MARK: - Re-check

    func testStaleSubscriptionIsRecheckedWithTheAppStore() async throws {
        let user = try await fixtures.user()
        let userID = try user.requireID()
        _ = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(3_600), appAccountToken: userID), as: user)
        let row = try await unwrapAsync(try await subscriptionRow())
        let now = Date().addingTimeInterval(3 * 86_400)
        try await (db as! any SQLDatabase).raw(
            """
            UPDATE subscriptions SET updated_at = \(bind: now.addingTimeInterval(-2 * 86_400))
            """
        ).run()

        let expired = try pki.sign(
            AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(3_600), appAccountToken: userID,
                signed: Date()))
        let client = SubscriptionTestStatusClient(
            response: AppStoreStatusResponse(data: [
                .init(lastTransactions: [
                    .init(
                        originalTransactionID: row.originalTransactionID, status: 2,
                        signedTransactionInfo: expired, signedRenewalInfo: nil)
                ])
            ]))
        let outcome = try await SubscriptionRecheckSweep.run(
            on: db, client: client, verifier: pki.verifier, now: now)
        XCTAssertEqual(outcome.checked, [try row.requireID()])
        XCTAssertEqual(client.requests, [row.originalTransactionID])

        let checked = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(checked.status, .expired)
        XCTAssertNotNil(checked.lastCheckedAt)
        XCTAssertEqual(checked.$user.id, userID)

        // Not stale any more (updated, expired rows are final): nothing to ask.
        let second = try await SubscriptionRecheckSweep.run(
            on: db, client: client, verifier: pki.verifier, now: now)
        XCTAssertEqual(second, .init())
    }

    func testFailedRecheckWaitsADay() async throws {
        let user = try await fixtures.user()
        _ = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(expires: Date().addingTimeInterval(3_600)), as: user)
        let now = Date().addingTimeInterval(3 * 86_400)
        try await (db as! any SQLDatabase).raw(
            "UPDATE subscriptions SET updated_at = \(bind: now.addingTimeInterval(-2 * 86_400))"
        ).run()
        let client = SubscriptionTestStatusClient(response: nil)
        let outcome = try await SubscriptionRecheckSweep.run(
            on: db, client: client, verifier: pki.verifier, now: now)
        XCTAssertEqual(outcome.failed.count, 1)
        let row = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(row.status, .active)
        XCTAssertNotNil(row.lastCheckedAt)

        let next = try await SubscriptionRecheckSweep.run(
            on: db, client: client, verifier: pki.verifier, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(next, .init())
    }
}

/// `SUBSCRIPTION_REQUIRED=true` — the 402 gate and expiry handling (2.3.3, 2.3.4).
final class SubscriptionRequiredDatabaseTests: SubscriptionDatabaseTestCase {
    override var subscriptionRequired: Bool { true }

    func testEntitlementFollowsTheSubscription() async throws {
        let user = try await fixtures.user()
        let none = try await subscriptionEntitlement(user)
        XCTAssertEqual(
            none, EntitlementResponse(subscriptionRequired: true, active: false, status: .none))
        try await assertEntitlementAgreesEverywhere(user, expected: none)

        let create = try await send(
            .POST, "/api/v1/groups", as: user,
            json: CreateGroupRequest(clientId: UUID(), name: "새벽 기도"))
        try assertError(create, .subscriptionRequired)

        let verify = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(86_400), appAccountToken: try user.requireID()),
            as: user)
        let entitlement = try decode(EntitlementResponse.self, from: verify)
        XCTAssertTrue(entitlement.subscriptionRequired)
        XCTAssertTrue(entitlement.active)
        expectEqual(try await subscriptionEntitlement(user), entitlement)
        try await assertEntitlementAgreesEverywhere(user, expected: entitlement)

        let created = try await send(
            .POST, "/api/v1/groups", as: user,
            json: CreateGroupRequest(clientId: UUID(), name: "새벽 기도"))
        XCTAssertEqual(created.status, .created, created.body.string)
    }

    func testExpiryRemovesTheMemberOnce() async throws {
        // Spec "플래그가 켜진 상태의 만료".
        let member = try await fixtures.user("멤버")
        let admin = try await fixtures.user("관리자")
        let other = try await fixtures.user("다른 멤버")
        let shared = try await fixtures.group(admin: admin, members: [member, other])
        let own = try await fixtures.group("내 모임", admin: member, members: [other])
        let memberID = try member.requireID()

        let memberPost = try await fixtures.post(by: member, in: shared)
        let photo = try await fixtures.media(uploadedBy: member, in: shared, post: memberPost)
        let adminPost = try await fixtures.post(by: admin, in: shared)
        let comment = Comment(
            postID: try adminPost.requireID(), authorID: memberID, body: "아멘", clientID: UUID())
        try await comment.create(on: db)
        let reaction = Reaction(
            postID: try adminPost.requireID(), userID: memberID, key: .emoji("🙏"))
        try await reaction.create(on: db)
        let profile = try await fixtures.media(uploadedBy: member, in: nil, purpose: .profile)

        _ = try await subscriptionNotify(
            type: "EXPIRED", subtype: "BILLING_RETRY",
            transaction: AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(-60), appAccountToken: memberID))

        let removals = try await SubscriptionRemovalSweep.run(
            on: db, dayLength: app.pilgrimConfig.dayLength, now: Date())
    func testDailyReportNeedsTheSubscription() async throws {
        let member = try await fixtures.user("멤버")
        let paid = try await fixtures.user("구독자")
        let admin = try await fixtures.user("관리자")
        _ = try await fixtures.group(admin: admin, members: [member, paid])
        let verified = try await subscriptionVerify(
            AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(86_400), appAccountToken: try paid.requireID()),
            as: paid)
        XCTAssertEqual(verified.status, .ok, verified.body.string)

        try assertError(
            try await send(.GET, "/api/v1/me/daily-report", as: member), .subscriptionRequired)
        let report = try await send(.GET, "/api/v1/me/daily-report", as: paid)
        XCTAssertEqual(report.status, .ok, report.body.string)

        // Both reports are due this minute; the nightly sweep builds only the entitled one.
        let now = Date()
        for user in [member, paid] {
            user.timeZone = "UTC"
            user.dailyReportMinute = Int(now.timeIntervalSince1970) % 86_400 / 60
            try await user.update(on: db)
        }
        _ = try await DailyReportSweep.run(
            on: db, config: app.pilgrimConfig, now: now, logger: app.logger)
        let logged = try await DailyReportLogEntry.query(on: db).all().map(\.$user.id)
        XCTAssertEqual(logged, [try paid.requireID()])
    }

        XCTAssertEqual(removals.count, 1)
        XCTAssertEqual(removals.first?.removedFromGroups, true)

        expectNil(
            try await ContentVisibility.membership(of: memberID, in: try shared.requireID(), on: db)
        )
        expectNil(
            try await ContentVisibility.membership(of: memberID, in: try own.requireID(), on: db))
        // The group the member ran goes to the one remaining member.
        let ownAfter = try await unwrapAsync(try await Group.find(try own.requireID(), on: db))
        XCTAssertEqual(ownAfter.$admin.id, try other.requireID())

        expectNil(try await Post.find(try memberPost.requireID(), on: db))
        expectNil(try await Media.find(try photo.requireID(), on: db))
        expectNil(try await Comment.find(try comment.requireID(), on: db))
        expectNil(try await Reaction.find(try reaction.requireID(), on: db))
        expectNotNil(try await Post.find(try adminPost.requireID(), on: db))
        expectNotNil(try await Media.find(try profile.requireID(), on: db))
        expectNotNil(try await User.find(memberID, on: db))
        expectNotNil(try await subscriptionRow()?.removalProcessedAt)

        // Only once: a second pass (or a duplicate EXPIRED) does nothing more.
        try await fixtures.join(member, shared)
        let again = try await SubscriptionRemovalSweep.run(
            on: db, dayLength: app.pilgrimConfig.dayLength, now: Date())
        XCTAssertEqual(again, [])
        expectNotNil(
            try await ContentVisibility.membership(of: memberID, in: try shared.requireID(), on: db)
        )
    }

    func testResubscribingArmsExpiryHandlingAgain() async throws {
        let member = try await fixtures.user()
        let memberID = try member.requireID()
        _ = try await subscriptionNotify(
            type: "EXPIRED",
            transaction: AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(-60), appAccountToken: memberID))
        _ = try await SubscriptionRemovalSweep.run(on: db, dayLength: 86_400, now: Date())
        expectNotNil(try await subscriptionRow()?.removalProcessedAt)

        _ = try await subscriptionNotify(
            type: "SUBSCRIBED", subtype: "RESUBSCRIBE",
            transaction: AppStoreTestPayloads.transaction(
                transactionID: "2000000000000002", expires: Date().addingTimeInterval(86_400),
                appAccountToken: memberID))
        let row = try await unwrapAsync(try await subscriptionRow())
        XCTAssertEqual(row.status, .active)
        XCTAssertNil(row.removalProcessedAt)
    }

    func testStillEntitledOwnerIsNotRemoved() async throws {
        let member = try await fixtures.user()
        let memberID = try member.requireID()
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        _ = try await subscriptionNotify(
            type: "EXPIRED",
            transaction: AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(-60), appAccountToken: memberID))
        _ = try await subscriptionNotify(
            type: "SUBSCRIBED",
            transaction: AppStoreTestPayloads.transaction(
                originalTransactionID: "2000000000000777",
                expires: Date().addingTimeInterval(86_400), appAccountToken: memberID))

        let removals = try await SubscriptionRemovalSweep.run(
            on: db, dayLength: 86_400, now: Date())
        XCTAssertEqual(removals.map(\.removedFromGroups), [false])
        expectNotNil(
            try await ContentVisibility.membership(of: memberID, in: try group.requireID(), on: db))
    }

    func testWorkerLoopHandlesExpiry() async throws {
        let member = try await fixtures.user()
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        _ = try await subscriptionNotify(
            type: "REVOKE",
            transaction: AppStoreTestPayloads.transaction(
                expires: Date().addingTimeInterval(86_400),
                revoked: Date(), appAccountToken: try member.requireID()))
        expectEqual(try await subscriptionRow()?.status, .revoked)

        let result = await WorkerRunner(application: app).runOnce(SubscriptionWorker.job())
        XCTAssertEqual(result, .ran)
        expectNil(
            try await ContentVisibility.membership(
                of: try member.requireID(), in: try group.requireID(), on: db))
    }
}

/// A fake App Store Server API: answers `response`, or fails when it is nil.
final class SubscriptionTestStatusClient: AppStoreStatusFetching {
    let response: AppStoreStatusResponse?
    private let asked = NIOLockedValueBox<[String]>([])

    init(response: AppStoreStatusResponse?) {
        self.response = response
    }

    var requests: [String] { asked.withLockedValue { $0 } }

    func subscriptionStatuses(
        originalTransactionID: String, bundleID: String,
        environment: AppStoreSubscription.Environment
    ) async throws -> AppStoreStatusResponse {
        asked.withLockedValue { $0.append(originalTransactionID) }
        guard let response else { throw AppStoreStatusError(status: 500) }
        return response
    }
}
