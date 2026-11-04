#if canImport(XCTest)
import Combine
import Foundation
import JournalData
import JournalSearch
@testable import PilgrimJournal
import XCTest

final class PremiumEntitlementTests: XCTestCase {
    private let premium = PremiumEntitlement.monthlyProductID

    func testNoEntitlementsIsNotPremium() {
        XCTAssertFalse(PremiumEntitlement.isPremium([]))
    }

    func testVerifiedSubscriptionIsPremium() {
        XCTAssertTrue(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(productID: premium, isVerified: true)
            ]))
    }

    func testUnverifiedTransactionDoesNotUnlock() {
        XCTAssertFalse(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(productID: premium, isVerified: false)
            ]))
    }

    func testRefundedSubscriptionDoesNotUnlock() {
        XCTAssertFalse(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(
                    productID: premium, isVerified: true, revocationDate: .now)
            ]))
    }

    func testUpgradedAwayTransactionDoesNotUnlockByItself() {
        XCTAssertFalse(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(productID: premium, isVerified: true, isUpgraded: true)
            ]))
    }

    func testOtherProductsDoNotUnlock() {
        XCTAssertFalse(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(productID: "com.example.other", isVerified: true)
            ]))
    }

    func testOneValidEntitlementAmongInvalidOnesUnlocks() {
        XCTAssertTrue(
            PremiumEntitlement.isPremium([
                PremiumEntitlementSnapshot(productID: premium, isVerified: false),
                PremiumEntitlementSnapshot(productID: "com.example.other", isVerified: true),
                PremiumEntitlementSnapshot(productID: premium, isVerified: true),
            ]))
    }

    func testCustomProductSetIsHonoured() {
        let yearly = "com.dhouse.PilgrimJournal.premium.yearly"
        let entitlements = [PremiumEntitlementSnapshot(productID: yearly, isVerified: true)]
        XCTAssertFalse(PremiumEntitlement.isPremium(entitlements))
        XCTAssertTrue(PremiumEntitlement.isPremium(entitlements, productIDs: [premium, yearly]))
    }

    /// The scheme's StoreKit configuration and App Store Connect must sell
    /// exactly the product the gate checks.
    func testStoreKitConfigurationSellsThePremiumProduct() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "PilgrimJournal/PilgrimJournal.storekit")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = try XCTUnwrap(json["subscriptionGroups"] as? [[String: Any]])
        let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
        let monthly = try XCTUnwrap(
            subscriptions.first { $0["productID"] as? String == premium })
        XCTAssertEqual(monthly["recurringSubscriptionPeriod"] as? String, "P1M")
        XCTAssertEqual(monthly["type"] as? String, "RecurringSubscription")
    }

    func testPriceWithPeriod() {
        var offer = PremiumOffer(
            displayName: "Pilgrim 프리미엄", displayPrice: "₩2,000", period: .month,
            periodLength: 1)
        XCTAssertEqual(offer.priceWithPeriod, "₩2,000 / 월")
        offer.period = .year
        offer.periodLength = 2
        XCTAssertEqual(offer.priceWithPeriod, "₩2,000 / 2년")
    }
}

@MainActor
private final class SwitchableFeatureAccess: FeatureAccess {
    var canManageKinds = false {
        didSet { subject.send() }
    }
    let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
}

@MainActor
final class FeatureAccessModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-feature-access-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testModelRepublishesWhenAccessChangesOutsideTheApp() throws {
        let access = SwitchableFeatureAccess()
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(url: paths.search.appending(path: "index.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: UserDefaults(
                suiteName: "pilgrim-feature-access-\(UUID().uuidString)")!,
            featureAccess: access
        )
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        // e.g. a renewal or an offer code redeemed in the App Store app.
        access.canManageKinds = true

        XCTAssertEqual(changes, 1)
        model.openKindManagement()
        XCTAssertTrue(model.isPresentingKindManagement)
    }

    func testSessionControllerDefaultsToUnlockedForTests() {
        let controller = JournalSessionController(
            rootURL: root, cloudKitContainerIdentifier: nil)
        XCTAssertTrue(controller.featureAccess.canManageKinds)
    }
}
#endif
