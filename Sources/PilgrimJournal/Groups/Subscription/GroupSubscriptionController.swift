import Combine
import Foundation
import JournalGroups
import PilgrimAPI

/// The two group-server calls the subscription makes.
protocol GroupSubscriptionServer: Sendable {
    func entitlement() async throws -> EntitlementResponse
    func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
}

/// `GroupSubscriptionServer` over the session's `GroupAPI` client.
struct GroupAPISubscriptionServer: GroupSubscriptionServer {
    let api: any GroupAPI

    func entitlement() async throws -> EntitlementResponse {
        try await api.entitlement()
    }

    func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
    {
        try await api.verifySubscription(request)
    }
}

/// What came of handing one transaction to the group server.
enum GroupTransactionDelivery: Equatable {
    case verified(EntitlementResponse)
    case waitingForSignIn
    case ownedByOtherUser
    case ignored
    case failed(GroupAPIError)
}

/// The group subscription (design.md 12): the App Store product, purchase with
/// `appAccountToken` = the group user ID, restore, and sending every signed transaction to
/// `POST /subscriptions/verify`, at launch (once the group profile is known) and for each
/// `Transaction.updates`.
///
/// One instance (`shared`) lives for the app run, so a single listener hears the StoreKit
/// updates; `attach(to:)` points it at the `GroupsController` the session shows, takes over
/// its `onSubscriptionRequired`, and skips the screen whenever the server's entitlement says
/// no subscription is needed (the launch setting, `SUBSCRIPTION_REQUIRED=false`).
@MainActor
final class GroupSubscriptionController: ObservableObject {
    static let shared = GroupSubscriptionController(store: StoreKitGroupSubscriptionStore())

    @Published private(set) var offer: GroupSubscriptionOffer?
    @Published private(set) var hasLoadedOffer = false
    /// The latest entitlement from the server (verification or `GET /me/entitlement`), else
    /// the group profile's.
    @Published private(set) var entitlement: EntitlementResponse?
    @Published private(set) var isWorking = false
    /// A purchase went through but the server could not be reached to verify it.
    @Published private(set) var isAwaitingServer = false
    @Published var message: String?

    private let store: any GroupSubscriptionStoring
    private let isEnabled: Bool
    private let bundleID: String
    private weak var groups: GroupsController?
    private var server: (any GroupSubscriptionServer)?
    private var observers: Set<AnyCancellable> = []
    private var updatesTask: Task<Void, Never>?
    /// The group user whose launch submission has run.
    private var submittedUserID: UUID?
    /// `GroupsController.presentedSheet`, now and before its last change.
    private var currentSheet: GroupsSheet?
    private var previousSheet: GroupsSheet?
    /// The sheet to reopen once the subscription is settled.
    private(set) var resumeSheet: GroupsSheet?
    /// The running `presentIfNeeded()` and launch submission, for tests to wait on.
    private(set) var presentationTask: Task<Void, Never>?
    private(set) var launchSubmissionTask: Task<Void, Never>?

    init(
        store: any GroupSubscriptionStoring, isEnabled: Bool = GroupsFeature.isEnabled,
        bundleID: String = GroupsController.defaultBundleID
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.bundleID = bundleID
    }

    var state: GroupSubscriptionState {
        guard let entitlement = entitlement ?? groups?.me?.entitlement else {
            return .required(nil)
        }
        return GroupSubscriptionState(entitlement: entitlement)
    }

    /// Whether purchase and restore can run: a group profile supplies the `appAccountToken`.
    var canPurchase: Bool { groups?.me != nil }

    // MARK: Attaching

    /// Serves `groups`: shows the subscription screen when it asks for one, and sends the
    /// App Store transactions once its profile is known. Starts the `Transaction.updates`
    /// listener on the first call. Does nothing while groups are off.
    func attach(to groups: GroupsController, server: (any GroupSubscriptionServer)? = nil) {
        guard isEnabled else { return }
        observers = []
        self.groups = groups
        self.server = server ?? GroupAPISubscriptionServer(api: groups.api)
        submittedUserID = nil
        entitlement = nil
        resumeSheet = nil
        currentSheet = groups.presentedSheet
        previousSheet = nil
        groups.onSubscriptionRequired = { [weak self] in self?.subscriptionRequired() }
        // `@Published` sends on every assignment, before the new value is stored.
        groups.$presentedSheet
            .sink { [weak self] sheet in
                MainActor.assumeIsolated { self?.sheetWillChange(to: sheet) }
            }
            .store(in: &observers)
        groups.$me
            .sink { [weak self] me in
                MainActor.assumeIsolated { self?.profileWillChange(to: me) }
            }
            .store(in: &observers)
        startObservingTransactions()
    }

    // MARK: The screen

    /// `GroupsController.requestSubscription()`. It has just closed the sheet that asked
    /// (join, create), which is reopened once the subscription is settled.
    func subscriptionRequired() {
        resumeSheet = GroupSubscriptionPolicy.resumeSheet(
            openWhenRequested: currentSheet ?? previousSheet)
        presentationTask = Task { await presentIfNeeded() }
    }

    /// Asks the server whether a subscription is needed: shows the screen if so, otherwise
    /// carries on with what asked for it.
    func presentIfNeeded() async {
        let fresh = await loadEntitlement()
        guard let groups else { return }
        if GroupSubscriptionPolicy.shouldPresentScreen(
            fresh: fresh, cached: groups.me?.entitlement)
        {
            message = nil
            isAwaitingServer = false
            groups.presentedSheet = .subscription
        } else {
            continueAfterSubscription()
        }
    }

    /// Reopens the sheet that needed the subscription, or closes the screen.
    func continueAfterSubscription() {
        let next = resumeSheet
        resumeSheet = nil
        groups?.presentedSheet = next
    }

    /// Loads the price and the entitlement for the screen.
    func loadScreen() async {
        if offer == nil {
            offer = await store.offer()
        }
        hasLoadedOffer = true
        _ = await loadEntitlement()
    }

    // MARK: Purchase and restore

    func purchase() async {
        guard !isWorking else { return }
        guard let userID = groups?.me?.id else {
            message = GroupSubscriptionMessages.signInFirst
            return
        }
        isWorking = true
        defer { isWorking = false }
        message = nil
        isAwaitingServer = false
        let result: GroupStorePurchaseResult
        do {
            result = try await store.purchase(appAccountToken: userID)
        } catch GroupStoreError.cancelled {
            return
        } catch GroupStoreError.failed(let reason) {
            message = GroupSubscriptionMessages.purchaseFailed(reason)
            return
        } catch {
            message = GroupSubscriptionMessages.purchaseFailed(error.localizedDescription)
            return
        }
        switch result {
        case .purchased(let transaction):
            guard transaction.isVerified else {
                message = GroupSubscriptionMessages.unverifiedPurchase
                return
            }
            settle(await deliver(transaction), restoring: false)
        case .pending:
            message = GroupSubscriptionMessages.pending
        case .cancelled:
            break
        case .unavailable:
            message = GroupSubscriptionMessages.storeUnavailable
        }
    }

    /// 구입 복원: `AppStore.sync()`, then the newest transaction goes to the server.
    func restore() async {
        guard !isWorking else { return }
        guard groups?.me != nil else {
            message = GroupSubscriptionMessages.signInFirst
            return
        }
        isWorking = true
        defer { isWorking = false }
        message = nil
        isAwaitingServer = false
        do {
            try await store.sync()
        } catch GroupStoreError.cancelled {
            return
        } catch GroupStoreError.failed(let reason) {
            message = GroupSubscriptionMessages.restoreFailed(reason)
            return
        } catch {
            message = GroupSubscriptionMessages.restoreFailed(error.localizedDescription)
            return
        }
        guard let transaction = await store.latestTransaction() else {
            message = GroupSubscriptionMessages.nothingToRestore
            return
        }
        settle(await deliver(transaction), restoring: true)
    }

    /// The screen's retry after a purchase the server could not verify, and the follow-up of
    /// an offer code redeemed in Apple's sheet.
    func verifyLatestTransaction() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        message = nil
        isAwaitingServer = false
        guard let transaction = await store.latestTransaction() else { return }
        settle(await deliver(transaction), restoring: false)
    }

    // MARK: Sending transactions

    /// Sends one transaction to the server (when the policy says so), finishes it once the
    /// server has answered for good, and brings `GroupsController` up to date.
    @discardableResult
    func deliver(_ transaction: GroupStoreTransaction) async -> GroupTransactionDelivery {
        switch GroupSubscriptionPolicy.submission(for: transaction, userID: groups?.me?.id) {
        case .ignore:
            return .ignored
        case .waitForSignIn:
            return .waitingForSignIn
        case .ownedByOtherUser:
            await store.finish(transaction)
            return .ownedByOtherUser
        case .submit:
            break
        }
        guard let server else { return .waitingForSignIn }
        let request = VerifySubscriptionRequest(
            signedTransaction: transaction.signedTransaction, bundleId: bundleID)
        do {
            let verified = try await server.verifySubscription(request)
            await store.finish(transaction)
            await apply(verified)
            return .verified(verified)
        } catch {
            let error = GroupsController.normalize(error)
            groups?.handle(error)
            if GroupSubscriptionPolicy.shouldFinish(after: error) {
                await store.finish(transaction)
            }
            return error.code == .subscriptionOwnedByOtherUser ? .ownedByOtherUser : .failed(error)
        }
    }

    /// The launch submission: the newest transaction, once per group user and app run.
    func submitLatestTransaction() async {
        guard let transaction = await store.latestTransaction() else { return }
        await deliver(transaction)
    }

    // MARK: Private

    private func settle(_ delivery: GroupTransactionDelivery, restoring: Bool) {
        switch delivery {
        case .verified(let verified):
            let state = GroupSubscriptionState(entitlement: verified)
            if state.needsPurchase {
                message =
                    restoring
                    ? GroupSubscriptionMessages.nothingToRestore
                    : GroupSubscriptionMessages.notActiveAfterVerification
            } else {
                message = restoring ? GroupSubscriptionMessages.restored : nil
                if resumeSheet != nil { continueAfterSubscription() }
            }
        case .ownedByOtherUser:
            message = GroupSubscriptionMessages.ownedByOtherUser
        case .waitingForSignIn:
            message = GroupSubscriptionMessages.signInFirst
        case .ignored:
            message = restoring ? GroupSubscriptionMessages.nothingToRestore : nil
        case .failed(let error):
            isAwaitingServer = error.isUnreachable
            message = GroupSubscriptionMessages.verificationFailed(error)
        }
    }

    private func apply(_ verified: EntitlementResponse) async {
        entitlement = verified
        if GroupSubscriptionPolicy.needsAccountReload(
            current: groups?.me?.entitlement, verified: verified)
        {
            await groups?.loadAccount()
        }
    }

    /// `GET /me/entitlement`; nil when the server cannot be reached. A change the profile
    /// does not know yet reloads it.
    private func loadEntitlement() async -> EntitlementResponse? {
        guard let server, groups?.me != nil else { return nil }
        guard let fresh = try? await server.entitlement() else { return nil }
        await apply(fresh)
        return fresh
    }

    private func sheetWillChange(to sheet: GroupsSheet?) {
        previousSheet = currentSheet
        currentSheet = sheet
    }

    private func profileWillChange(to me: MeResponse?) {
        guard let me else {
            submittedUserID = nil
            entitlement = nil
            return
        }
        entitlement = me.entitlement
        guard me.id != submittedUserID else { return }
        submittedUserID = me.id
        launchSubmissionTask = Task { await submitLatestTransaction() }
    }

    private func startObservingTransactions() {
        guard updatesTask == nil else { return }
        let updates = store.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await transaction in updates {
                guard let self else { return }
                await self.deliver(transaction)
            }
        }
    }
}
