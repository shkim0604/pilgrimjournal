#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

#if canImport(StoreKitTest)
import StoreKit
import StoreKitTest
#endif

/// `PilgrimJournal/PilgrimJournal.storekit`, the StoreKit configuration for local testing.
enum GroupSubscriptionStoreKitConfiguration {
    static let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "PilgrimJournal/PilgrimJournal.storekit")
}

/// The configuration must sell exactly the product the app buys and the server verifies
/// (design.md 12), so App Store Connect can be set up from it.
final class GroupSubscriptionStoreKitConfigurationTests: XCTestCase {
    private func configuration() throws -> [String: Any] {
        let data = try Data(contentsOf: GroupSubscriptionStoreKitConfiguration.url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testConfigurationSellsTheMonthlyGroupSubscriptionOnly() throws {
        let json = try configuration()
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1, "one subscription group")
        let subscriptions = try XCTUnwrap(groups.first?["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(subscriptions.count, 1)
        let monthly = try XCTUnwrap(subscriptions.first)
        XCTAssertEqual(monthly["productID"] as? String, SubscriptionProduct.groupsMonthly)
        XCTAssertEqual(monthly["productID"] as? String, GroupSubscriptionPolicy.productID)
        XCTAssertEqual(monthly["recurringSubscriptionPeriod"] as? String, "P1M")
        XCTAssertEqual(monthly["type"] as? String, "RecurringSubscription")
        XCTAssertEqual(monthly["familyShareable"] as? Bool, false)
        XCTAssertEqual(
            monthly["subscriptionGroupID"] as? String, groups.first?["id"] as? String)
        XCTAssertEqual(
            (json["products"] as? [Any])?.count, 0, "no consumables or one-time purchases")
        XCTAssertEqual((json["nonRenewingSubscriptions"] as? [Any])?.count, 0)
    }

    func testConfigurationPricesTheKoreanStorefrontAt2000Won() throws {
        let json = try configuration()
        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        XCTAssertEqual(settings["_storefront"] as? String, "KOR")
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        let monthly = try XCTUnwrap((groups.first?["subscriptions"] as? [[String: Any]])?.first)
        XCTAssertEqual(monthly["displayPrice"] as? String, "2000")
    }
}

#if canImport(StoreKitTest)
/// The real `StoreKitGroupSubscriptionStore` against the configuration file in an
/// `SKTestSession` (tasks 2.8.3).
///
/// StoreKit Testing serves the configuration to the iOS Simulator test run (CI's iOS job, and
/// `xcodebuild test -scheme PilgrimJournal-Package -destination 'platform=iOS Simulator,…'`).
/// A command-line `swift test` on macOS loads no products, so there these are skipped unless
/// `PILGRIM_STOREKIT_TESTS=1` asks for them.
///
/// Buying needs an app-hosted test bundle: the package's test bundle runs in `xctest`, which
/// StoreKit gives no transactions (`buyProduct` logs "didn't return the expected transaction
/// JWS"). The purchase tests skip themselves there and run once a hosted test target exists;
/// until then the purchase sheet is checked by hand with the scheme's StoreKit configuration.
@MainActor
final class GroupSubscriptionStoreKitTests: XCTestCase {
    private static let subscribed = EntitlementResponse(
        subscriptionRequired: true, active: true, status: .active,
        productId: SubscriptionProduct.groupsMonthly, expiresAt: Date() + 30 * 86_400)

    private let product = SubscriptionProduct.groupsMonthly
    private var session: SKTestSession!

    override func setUp() async throws {
        guard Self.storeKitTestingIsServed else {
            throw XCTSkip(
                "StoreKit Testing runs on the iOS Simulator or with PILGRIM_STOREKIT_TESTS=1.")
        }
        session = try SKTestSession(contentsOf: GroupSubscriptionStoreKitConfiguration.url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
    }

    func testOfferComesFromTheConfiguration() async throws {
        let store = StoreKitGroupSubscriptionStore()
        let offer = try await unwrapAsync(await store.offer())
        XCTAssertEqual(offer.period, .month)
        XCTAssertEqual(offer.periodLength, 1)
        XCTAssertEqual(offer.displayName, "Pilgrim 그룹 (월간)")
        XCTAssertTrue(offer.displayPrice.contains("2,000"), offer.displayPrice)
    }

    func testSignedTransactionCarriesTheGroupUserID() async throws {
        let store = StoreKitGroupSubscriptionStore()
        let before = await store.latestTransaction()
        XCTAssertNil(before)
        let userID = UUID()
        try await buy(for: userID)

        let transaction = try await unwrapAsync(await store.latestTransaction())
        XCTAssertTrue(transaction.isVerified)
        XCTAssertEqual(transaction.productID, product)
        XCTAssertEqual(transaction.appAccountToken, userID)
        XCTAssertNil(transaction.revocationDate)
        XCTAssertEqual(
            transaction.signedTransaction.split(separator: ".").count, 3, "a compact JWS")
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction, userID: userID), .submit)
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction, userID: UUID()),
            .ownedByOtherUser)
        await store.finish(transaction)
    }

    func testLaunchSendsTheSubscriptionToTheServer() async throws {
        let groups = GroupsMembershipFixtures.controller(api: PreviewGroupAPI())
        await groups.loadAccount()
        let userID = try XCTUnwrap(groups.me?.id)
        try await buy(for: userID)
        let server = FakeGroupSubscriptionServer(verify: .success(Self.subscribed))
        let subscription = GroupSubscriptionController(
            store: StoreKitGroupSubscriptionStore(), isEnabled: true, bundleID: BundleIDs.debug)

        subscription.attach(to: groups, server: server)
        await subscription.launchSubmissionTask?.value

        let requests = await server.verified
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.bundleId, BundleIDs.debug)
        XCTAssertEqual(requests.first?.signedTransaction.split(separator: ".").count, 3)
        withExtendedLifetime(groups) {}
    }

    func testExpiredSubscriptionIsStillSentSoTheServerLearnsItEnded() async throws {
        let store = StoreKitGroupSubscriptionStore()
        let userID = UUID()
        try await buy(for: userID)
        let purchase = try await unwrapAsync(await store.latestTransaction())
        try session.expireSubscription(productIdentifier: product)

        let latest = try await unwrapAsync(await store.latestTransaction())
        XCTAssertEqual(latest.originalID, purchase.originalID)
        let expiry = try XCTUnwrap(latest.expirationDate)
        XCTAssertLessThanOrEqual(expiry, Date().addingTimeInterval(1))
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: latest, userID: userID), .submit,
            "the server, not the app, decides what an ended subscription means")
    }

    private static var storeKitTestingIsServed: Bool {
        #if os(iOS) && targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.environment["PILGRIM_STOREKIT_TESTS"] == "1"
        #endif
    }

    /// An off-device purchase for the group user, with the same `appAccountToken` option the
    /// app passes to `Product.purchase`. Skips the test where StoreKit hands this process no
    /// transactions (a test bundle without an app host).
    private func buy(for userID: UUID) async throws {
        do {
            _ = try await session.buyProduct(
                identifier: product, options: [.appAccountToken(userID)])
        } catch {
            guard await Transaction.latest(for: product) != nil else {
                throw XCTSkip("Purchases need an app-hosted test bundle: \(error)")
            }
        }
    }

    private func unwrapAsync<T>(
        _ value: @autoclosure () async throws -> T?, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> T {
        let value = try await value()
        return try XCTUnwrap(value, file: file, line: line)
    }
}
#endif
#endif
