#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

/// StoreKit in memory: what the controller bought, synced and finished.
@MainActor
final class FakeGroupSubscriptionStore: GroupSubscriptionStoring {
    var offerValue: GroupSubscriptionOffer? = GroupSubscriptionOffer(
        displayName: "Pilgrim 그룹 (월간)", displayPrice: "₩2,000", period: .month, periodLength: 1)
    /// What `purchase` answers; `.purchased` gets the token the controller passed.
    var purchaseAnswer: Result<GroupStorePurchaseResult, GroupStoreError> = .success(.cancelled)
    var syncError: GroupStoreError?
    var latest: GroupStoreTransaction?
    private(set) var purchaseTokens: [UUID] = []
    private(set) var syncCount = 0
    private(set) var finished: [UInt64] = []
    private let updates: AsyncStream<GroupStoreTransaction>
    private let continuation: AsyncStream<GroupStoreTransaction>.Continuation
    private(set) var updatesRequested = 0

    init() {
        (updates, continuation) = AsyncStream.makeStream()
    }

    func yield(_ transaction: GroupStoreTransaction) {
        continuation.yield(transaction)
    }

    func offer() async -> GroupSubscriptionOffer? { offerValue }

    func purchase(appAccountToken: UUID) async throws -> GroupStorePurchaseResult {
        purchaseTokens.append(appAccountToken)
        return try purchaseAnswer.get()
    }

    func sync() async throws {
        syncCount += 1
        if let syncError { throw syncError }
    }

    func latestTransaction() async -> GroupStoreTransaction? { latest }

    func finish(_ transaction: GroupStoreTransaction) async {
        finished.append(transaction.id)
    }

    func transactionUpdates() -> AsyncStream<GroupStoreTransaction> {
        updatesRequested += 1
        return updates
    }
}

/// `GET /me/entitlement` and `POST /subscriptions/verify` with set answers.
actor FakeGroupSubscriptionServer: GroupSubscriptionServer {
    var entitlementAnswer: Result<EntitlementResponse, GroupAPIError>
    var verifyAnswer: Result<EntitlementResponse, GroupAPIError>
    private(set) var verified: [VerifySubscriptionRequest] = []
    private(set) var entitlementCalls = 0

    init(
        entitlement: Result<EntitlementResponse, GroupAPIError> = .success(.notRequired),
        verify: Result<EntitlementResponse, GroupAPIError> = .success(.notRequired)
    ) {
        self.entitlementAnswer = entitlement
        self.verifyAnswer = verify
    }

    func setVerify(_ answer: Result<EntitlementResponse, GroupAPIError>) {
        verifyAnswer = answer
    }

    func entitlement() async throws -> EntitlementResponse {
        entitlementCalls += 1
        return try entitlementAnswer.get()
    }

    func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
    {
        verified.append(request)
        return try verifyAnswer.get()
    }
}

@MainActor
final class GroupSubscriptionControllerTests: XCTestCase {
    private typealias Fixtures = GroupsMembershipFixtures

    private static let required = EntitlementResponse(
        subscriptionRequired: true, active: false, status: .none)
    private static let subscribed = EntitlementResponse(
        subscriptionRequired: true, active: true, status: .active,
        productId: SubscriptionProduct.groupsMonthly, expiresAt: Date() + 30 * 86_400)

    private var store: FakeGroupSubscriptionStore!
    /// Keeps the groups controller alive: the subscription controller holds it weakly.
    private var groups: GroupsController?

    override func setUp() async throws {
        store = FakeGroupSubscriptionStore()
    }

    private func makeController(isEnabled: Bool = true) -> GroupSubscriptionController {
        GroupSubscriptionController(store: store, isEnabled: isEnabled, bundleID: BundleIDs.debug)
    }

    /// A signed-in group user (PreviewGroupAPI) served by `subscription`.
    private func signedIn(
        _ subscription: GroupSubscriptionController, server: FakeGroupSubscriptionServer? = nil
    ) async -> GroupsController {
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        self.groups = groups
        subscription.attach(to: groups, server: server)
        await groups.loadAccount()
        await subscription.launchSubmissionTask?.value
        return groups
    }

    private func transaction(
        id: UInt64 = 7, token: UUID?, verified: Bool = true
    ) -> GroupStoreTransaction {
        GroupStoreTransaction(
            id: id, productID: SubscriptionProduct.groupsMonthly,
            signedTransaction: "signed-\(id)", isVerified: verified, appAccountToken: token)
    }

    private func code() throws -> InviteCode {
        try XCTUnwrap(InviteCode(normalizing: PreviewGroupAPI.sampleInviteCode))
    }

    // MARK: Skipping the screen

    func testScreenIsSkippedAndTheJoinResumesWhileSubscriptionsAreOff() async throws {
        let subscription = makeController()
        // The real adapter over PreviewGroupAPI, which answers `subscriptionRequired: false`.
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        subscription.attach(to: groups)
        await groups.loadAccount()
        let code = try code()
        groups.presentedSheet = .join(GroupJoinRequest(code: code))

        groups.requestSubscription()
        await subscription.presentationTask?.value

        guard case .join(let request) = groups.presentedSheet else {
            return XCTFail("the join sheet comes back instead of the subscription screen")
        }
        XCTAssertEqual(request.code, code)
        XCTAssertEqual(subscription.state, .notRequired)
    }

    func testScreenIsSkippedWhenTheServerSaysTheUserIsSubscribed() async {
        let server = FakeGroupSubscriptionServer(entitlement: .success(Self.subscribed))
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        groups.presentedSheet = .createGroup

        groups.requestSubscription()
        await subscription.presentationTask?.value

        XCTAssertEqual(groups.presentedSheet, .createGroup)
    }

    func testDisabledFeatureLeavesGroupsAlone() async {
        let subscription = makeController(isEnabled: false)
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        subscription.attach(to: groups)
        XCTAssertNil(groups.onSubscriptionRequired)
        XCTAssertEqual(store.updatesRequested, 0, "no StoreKit listener while groups are off")
    }

    // MARK: Showing and buying

    func testRequiredSubscriptionShowsTheScreenAndThePurchaseResumesTheJoin() async throws {
        let server = FakeGroupSubscriptionServer(
            entitlement: .success(Self.required), verify: .success(Self.subscribed))
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        let userID = try XCTUnwrap(groups.me?.id)
        let code = try code()
        groups.presentedSheet = .join(GroupJoinRequest(code: code))

        groups.requestSubscription()
        await subscription.presentationTask?.value
        XCTAssertEqual(groups.presentedSheet, .subscription)

        await subscription.loadScreen()
        XCTAssertEqual(subscription.offer?.priceWithPeriod, "₩2,000 / 월")
        store.purchaseAnswer = .success(.purchased(transaction(token: userID)))
        await subscription.purchase()

        XCTAssertEqual(store.purchaseTokens, [userID], "appAccountToken is the group user ID")
        let requests = await server.verified
        XCTAssertEqual(
            requests,
            [VerifySubscriptionRequest(signedTransaction: "signed-7", bundleId: BundleIDs.debug)])
        XCTAssertEqual(store.finished, [7])
        XCTAssertNil(subscription.message)
        guard case .join(let request) = groups.presentedSheet else {
            return XCTFail("the join continues after the purchase")
        }
        XCTAssertEqual(request.code, code)
    }

    func testPurchaseNeedsAGroupProfile() async {
        let subscription = makeController()
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        self.groups = groups
        subscription.attach(to: groups, server: FakeGroupSubscriptionServer())
        XCTAssertFalse(subscription.canPurchase)
        await subscription.purchase()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.signInFirst)
        XCTAssertTrue(store.purchaseTokens.isEmpty)
    }

    func testPendingCancelledUnavailableAndFailedPurchases() async {
        let subscription = makeController()
        _ = await signedIn(subscription, server: FakeGroupSubscriptionServer())

        store.purchaseAnswer = .success(.pending)
        await subscription.purchase()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.pending)

        store.purchaseAnswer = .success(.cancelled)
        await subscription.purchase()
        XCTAssertNil(subscription.message)

        store.purchaseAnswer = .failure(.cancelled)
        await subscription.purchase()
        XCTAssertNil(subscription.message)

        store.purchaseAnswer = .success(.unavailable)
        await subscription.purchase()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.storeUnavailable)

        store.purchaseAnswer = .failure(.failed("결제 오류"))
        await subscription.purchase()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.purchaseFailed("결제 오류"))

        store.purchaseAnswer = .success(.purchased(transaction(token: nil, verified: false)))
        await subscription.purchase()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.unverifiedPurchase)
        XCTAssertTrue(store.finished.isEmpty)
    }

    func testUnreachableServerKeepsThePurchaseOpenForARetry() async throws {
        let server = FakeGroupSubscriptionServer(verify: .failure(.offline))
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        let purchase = transaction(token: try XCTUnwrap(groups.me?.id))
        store.purchaseAnswer = .success(.purchased(purchase))

        await subscription.purchase()
        XCTAssertTrue(subscription.isAwaitingServer)
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.awaitingServer)
        XCTAssertTrue(store.finished.isEmpty, "left open so StoreKit offers it again")

        await server.setVerify(.success(Self.subscribed))
        store.latest = purchase
        await subscription.verifyLatestTransaction()
        XCTAssertFalse(subscription.isAwaitingServer)
        XCTAssertEqual(store.finished, [7])
    }

    func testServerRejectionFinishesTheTransaction() async throws {
        let server = FakeGroupSubscriptionServer(verify: .failure(.server(.subscriptionInvalid)))
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        store.purchaseAnswer = .success(
            .purchased(transaction(token: try XCTUnwrap(groups.me?.id))))

        await subscription.purchase()
        XCTAssertEqual(store.finished, [7])
        XCTAssertFalse(subscription.isAwaitingServer)
        XCTAssertEqual(
            subscription.message, GroupAPIError.server(.subscriptionInvalid).localizedMessage)
    }

    // MARK: Restore

    func testRestore() async throws {
        let server = FakeGroupSubscriptionServer(verify: .success(Self.subscribed))
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)

        await subscription.restore()
        XCTAssertEqual(store.syncCount, 1)
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.nothingToRestore)

        store.syncError = .cancelled
        await subscription.restore()
        XCTAssertNil(subscription.message)

        store.syncError = nil
        store.latest = transaction(id: 9, token: try XCTUnwrap(groups.me?.id))
        await subscription.restore()
        XCTAssertEqual(subscription.message, GroupSubscriptionMessages.restored)
        XCTAssertEqual(store.finished, [9])

        await server.setVerify(.success(Self.required))
        await subscription.restore()
        XCTAssertEqual(
            subscription.message, GroupSubscriptionMessages.nothingToRestore,
            "an expired subscription restores nothing")
    }

    // MARK: Sending transactions

    func testLaunchSendsTheLatestTransactionOncePerGroupUser() async throws {
        store.latest = transaction(token: nil)
        let server = FakeGroupSubscriptionServer()
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        var requests = await server.verified
        XCTAssertEqual(requests.map(\.signedTransaction), ["signed-7"])

        await groups.loadAccount()
        await subscription.launchSubmissionTask?.value
        requests = await server.verified
        XCTAssertEqual(requests.count, 1, "the same user is not sent again this run")
    }

    func testTransactionsWaitForTheGroupSignIn() async {
        let server = FakeGroupSubscriptionServer()
        let subscription = makeController()
        let groups = Fixtures.controller(api: PreviewGroupAPI())
        self.groups = groups
        subscription.attach(to: groups, server: server)

        let delivery = await subscription.deliver(transaction(token: UUID()))
        XCTAssertEqual(delivery, .waitingForSignIn)
        XCTAssertTrue(store.finished.isEmpty)
        let requests = await server.verified
        XCTAssertTrue(requests.isEmpty)
    }

    func testAnotherGroupAccountsTransactionIsNotSent() async {
        let server = FakeGroupSubscriptionServer()
        let subscription = makeController()
        _ = await signedIn(subscription, server: server)

        let delivery = await subscription.deliver(transaction(token: UUID()))
        XCTAssertEqual(delivery, .ownedByOtherUser)
        XCTAssertEqual(store.finished, [7])
        let requests = await server.verified
        XCTAssertTrue(requests.isEmpty)

        let unverified = await subscription.deliver(
            transaction(id: 8, token: nil, verified: false))
        XCTAssertEqual(unverified, .ignored)
    }

    func testTransactionUpdatesAreSentToTheServer() async throws {
        let server = FakeGroupSubscriptionServer()
        let subscription = makeController()
        let groups = await signedIn(subscription, server: server)
        XCTAssertEqual(store.updatesRequested, 1)
        subscription.attach(to: groups, server: server)
        XCTAssertEqual(store.updatesRequested, 1, "one listener per app run")

        store.yield(transaction(id: 11, token: try XCTUnwrap(groups.me?.id)))
        for _ in 0..<100 where store.finished.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await server.verified
        XCTAssertEqual(requests.map(\.signedTransaction), ["signed-11"])
        XCTAssertEqual(store.finished, [11])
    }
}
#endif
