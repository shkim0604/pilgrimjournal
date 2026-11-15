import Foundation
import StoreKit

/// The part of a StoreKit transaction the group subscription needs. StoreKit's `Transaction`
/// cannot be built in tests, so the controller and the policy work on this.
struct GroupStoreTransaction: Equatable, Sendable {
    var id: UInt64
    var originalID: UInt64
    var productID: String
    /// `VerificationResult.jwsRepresentation`, sent to `POST /subscriptions/verify`.
    var signedTransaction: String
    /// False when StoreKit could not verify the signature on this device.
    var isVerified: Bool
    /// The group user ID the purchase was made for (nil for offer codes and purchases made
    /// outside the app).
    var appAccountToken: UUID?
    var revocationDate: Date?
    var expirationDate: Date?

    init(
        id: UInt64, originalID: UInt64? = nil, productID: String, signedTransaction: String,
        isVerified: Bool = true, appAccountToken: UUID? = nil, revocationDate: Date? = nil,
        expirationDate: Date? = nil
    ) {
        self.id = id
        self.originalID = originalID ?? id
        self.productID = productID
        self.signedTransaction = signedTransaction
        self.isVerified = isVerified
        self.appAccountToken = appAccountToken
        self.revocationDate = revocationDate
        self.expirationDate = expirationDate
    }

    init(_ result: VerificationResult<Transaction>) {
        let transaction = result.unsafePayloadValue
        let isVerified: Bool
        if case .verified = result { isVerified = true } else { isVerified = false }
        self.init(
            id: transaction.id, originalID: transaction.originalID,
            productID: transaction.productID, signedTransaction: result.jwsRepresentation,
            isVerified: isVerified, appAccountToken: transaction.appAccountToken,
            revocationDate: transaction.revocationDate,
            expirationDate: transaction.expirationDate)
    }
}

enum GroupStorePurchaseResult: Equatable, Sendable {
    case purchased(GroupStoreTransaction)
    /// Waiting on Ask to Buy or a payment update; it arrives later through
    /// `Transaction.updates`.
    case pending
    case cancelled
    /// The product could not be loaded (offline, or not set up in App Store Connect).
    case unavailable
}

enum GroupStoreError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// The StoreKit boundary of the group subscription. `StoreKitGroupSubscriptionStore` is the
/// real one; tests use a fake.
@MainActor
protocol GroupSubscriptionStoring: AnyObject {
    /// The product as the App Store prices it, or nil when the store cannot be reached.
    func offer() async -> GroupSubscriptionOffer?
    /// Buys the subscription for the group user `appAccountToken`.
    func purchase(appAccountToken: UUID) async throws -> GroupStorePurchaseResult
    /// `AppStore.sync()` (구입 복원). Throws `GroupStoreError`.
    func sync() async throws
    /// The newest transaction for the product, expired and refunded ones included, so the
    /// server also learns that a subscription ended.
    func latestTransaction() async -> GroupStoreTransaction?
    func finish(_ transaction: GroupStoreTransaction) async
    /// `Transaction.updates`: renewals, refunds, Ask to Buy approvals, offer codes, purchases
    /// on other devices. Called once per app run.
    func transactionUpdates() -> AsyncStream<GroupStoreTransaction>
}

/// StoreKit 2. Nothing touches StoreKit until a method is called, so building one (the
/// shared controller, tests) costs nothing.
@MainActor
final class StoreKitGroupSubscriptionStore: GroupSubscriptionStoring {
    let productID: String
    private var product: Product?
    /// The StoreKit transactions handed out, so `finish` can finish them.
    private var transactions: [UInt64: Transaction] = [:]

    init(productID: String = GroupSubscriptionPolicy.productID) {
        self.productID = productID
    }

    func offer() async -> GroupSubscriptionOffer? {
        await loadProduct()
        return product.flatMap(Self.offer(for:))
    }

    func purchase(appAccountToken: UUID) async throws -> GroupStorePurchaseResult {
        await loadProduct()
        guard let product else { return .unavailable }
        do {
            switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
            case .success(let result):
                return .purchased(remember(result))
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            throw GroupStoreError.failed(error.localizedDescription)
        }
    }

    func sync() async throws {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            throw GroupStoreError.cancelled
        } catch {
            throw GroupStoreError.failed(error.localizedDescription)
        }
    }

    func latestTransaction() async -> GroupStoreTransaction? {
        guard let result = await Transaction.latest(for: productID) else { return nil }
        return remember(result)
    }

    func finish(_ transaction: GroupStoreTransaction) async {
        guard let storeTransaction = transactions.removeValue(forKey: transaction.id) else {
            return
        }
        await storeTransaction.finish()
    }

    func transactionUpdates() -> AsyncStream<GroupStoreTransaction> {
        AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await result in Transaction.updates {
                    guard let self else { break }
                    continuation.yield(self.remember(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Private

    /// Fetched until one has loaded; offline keeps nil and the screen says the store is
    /// unavailable.
    private func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [productID]).first { $0.id == productID }
    }

    private func remember(_ result: VerificationResult<Transaction>) -> GroupStoreTransaction {
        let snapshot = GroupStoreTransaction(result)
        transactions[snapshot.id] = result.unsafePayloadValue
        return snapshot
    }

    private static func offer(for product: Product) -> GroupSubscriptionOffer? {
        guard let subscription = product.subscription else { return nil }
        let period: GroupSubscriptionOffer.Period
        switch subscription.subscriptionPeriod.unit {
        case .day: period = .day
        case .week: period = .week
        case .month: period = .month
        case .year: period = .year
        @unknown default: period = .month
        }
        return GroupSubscriptionOffer(
            displayName: product.displayName, displayPrice: product.displayPrice,
            period: period, periodLength: subscription.subscriptionPeriod.value)
    }
}
