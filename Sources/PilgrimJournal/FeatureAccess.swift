import Combine
import Foundation
import StoreKit

/// The single gate for paid features. Every premium check goes through here.
///
/// Paid features are sold only through App Store in-app purchases (guideline
/// 3.1.1): today one auto-renewing subscription, Pilgrim Premium. Codes are
/// App Store offer codes, redeemed in Apple's own sheet, so they arrive here
/// as ordinary subscription transactions.
@MainActor
protocol FeatureAccess: AnyObject {
    /// Creating, editing, reordering, deleting and restoring journal kinds.
    var canManageKinds: Bool { get }
    /// Whether the Apple ID on this device holds the paid features.
    var isPremium: Bool { get }
    /// Fires after `isPremium`, `canManageKinds` or `premiumOffer` may have
    /// changed, including from transactions made outside the app.
    var changes: AnyPublisher<Void, Never> { get }
    /// The subscription as the App Store sells it in this storefront; nil
    /// until `refresh()` has loaded it, or when the store cannot be reached.
    var premiumOffer: PremiumOffer? { get }
    /// Reloads the offer and re-reads the current entitlements, so an
    /// expired or refunded subscription locks again.
    func refresh() async
    func purchasePremium() async -> PremiumPurchaseOutcome
    /// Asks the App Store for this Apple ID's purchases (구입 복원).
    func restorePurchases() async -> PremiumRestoreOutcome
}

extension FeatureAccess {
    var isPremium: Bool { canManageKinds }
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var premiumOffer: PremiumOffer? { nil }
    func refresh() async {}
    func purchasePremium() async -> PremiumPurchaseOutcome { .unavailable }
    func restorePurchases() async -> PremiumRestoreOutcome { .unavailable }
}

/// Grants every feature. The default for tests.
@MainActor
final class UnlockedFeatureAccess: FeatureAccess {
    var canManageKinds: Bool { true }
}

/// The premium subscription as the App Store prices it.
struct PremiumOffer: Equatable, Sendable {
    enum Period: Equatable, Sendable {
        case day, week, month, year
    }

    var displayName: String
    /// Already formatted for the storefront, e.g. "₩2,000" or "$1.99".
    var displayPrice: String
    var period: Period
    var periodLength: Int

    /// "₩2,000 / 월" — the price with its billing period, as subscription
    /// disclosures (guideline 3.1.2) require.
    var priceWithPeriod: String {
        "\(displayPrice) / \(periodDescription)"
    }

    private var periodDescription: String {
        let length = periodLength
        guard length != 1 else {
            switch period {
            case .day: return String(localized: "premium.period.day", defaultValue: "일")
            case .week: return String(localized: "premium.period.week", defaultValue: "주")
            case .month: return String(localized: "premium.period.month", defaultValue: "월")
            case .year: return String(localized: "premium.period.year", defaultValue: "년")
            }
        }
        switch period {
        case .day: return String(localized: "premium.period.days", defaultValue: "\(length)일")
        case .week: return String(localized: "premium.period.weeks", defaultValue: "\(length)주")
        case .month:
            return String(localized: "premium.period.months", defaultValue: "\(length)개월")
        case .year: return String(localized: "premium.period.years", defaultValue: "\(length)년")
        }
    }
}

enum PremiumPurchaseOutcome: Equatable, Sendable {
    case purchased
    /// Waiting on Ask to Buy or a payment method update; it arrives later
    /// through `Transaction.updates`.
    case pending
    case cancelled
    case unavailable
    case failed(String)
}

enum PremiumRestoreOutcome: Equatable, Sendable {
    case restored
    case nothingToRestore
    case cancelled
    case unavailable
    case failed(String)
}

/// The part of a StoreKit transaction that decides an entitlement. StoreKit's
/// `Transaction` cannot be built in tests, so the decision runs on this.
struct PremiumEntitlementSnapshot: Equatable, Sendable {
    var productID: String
    /// False when StoreKit could not verify the transaction's signature.
    var isVerified: Bool
    var revocationDate: Date?
    /// True when the customer moved to another subscription in the group;
    /// that one carries the entitlement instead.
    var isUpgraded: Bool

    init(productID: String, isVerified: Bool, revocationDate: Date? = nil, isUpgraded: Bool = false)
    {
        self.productID = productID
        self.isVerified = isVerified
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
    }

    init(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            self.init(transaction, isVerified: true)
        case .unverified(let transaction, _):
            self.init(transaction, isVerified: false)
        }
    }

    private init(_ transaction: Transaction, isVerified: Bool) {
        self.init(
            productID: transaction.productID,
            isVerified: isVerified,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded
        )
    }
}

enum PremiumEntitlement {
    /// The monthly Pilgrim Premium subscription. App Store Connect must use
    /// exactly this ID; `PilgrimJournal/PilgrimJournal.storekit` mirrors it
    /// for local testing.
    nonisolated static let monthlyProductID = "com.dhouse.PilgrimJournal.premium.monthly"
    nonisolated static let productIDs: Set<String> = [monthlyProductID]

    /// Whether `entitlements` (from `Transaction.currentEntitlements`) grant
    /// premium. Expiry is StoreKit's call: current entitlements already drop
    /// lapsed subscriptions and keep ones in a billing grace period.
    static func isPremium(
        _ entitlements: [PremiumEntitlementSnapshot],
        productIDs: Set<String> = productIDs
    ) -> Bool {
        entitlements.contains { entitlement in
            entitlement.isVerified
                && productIDs.contains(entitlement.productID)
                && entitlement.revocationDate == nil
                && !entitlement.isUpgraded
        }
    }
}

/// Paid features unlock while this Apple ID holds the Pilgrim Premium
/// subscription. One instance lives for the whole app run, so it hears every
/// `Transaction.updates` (renewals, refunds, Ask to Buy approvals, offer codes
/// redeemed in the App Store app) and finishes those transactions.
@MainActor
final class StoreKitFeatureAccess: FeatureAccess {
    #if DEBUG
    /// Settings › 개발 toggle that locks paid features even while subscribed.
    static let simulateLockedKey = "debug-simulate-premium-locked"
    #endif

    private(set) var isPremium = false {
        didSet {
            if isPremium != oldValue { changeSubject.send() }
        }
    }
    private(set) var premiumOffer: PremiumOffer? {
        didSet {
            if premiumOffer != oldValue { changeSubject.send() }
        }
    }
    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

    private let changeSubject = PassthroughSubject<Void, Never>()
    private let productIDs: Set<String>
    private let defaults: UserDefaults
    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    init(
        productIDs: Set<String> = PremiumEntitlement.productIDs, defaults: UserDefaults = .standard
    ) {
        self.productIDs = productIDs
        self.defaults = defaults
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    var canManageKinds: Bool {
        #if DEBUG
        if defaults.bool(forKey: Self.simulateLockedKey) { return false }
        #endif
        return isPremium
    }

    /// Runs on every return to the app, so the product is fetched only until
    /// one has loaded; entitlements are re-read every time.
    func refresh() async {
        if product == nil { await loadProduct() }
        await refreshEntitlements()
    }

    func purchasePremium() async -> PremiumPurchaseOutcome {
        if product == nil { await loadProduct() }
        guard let product else { return .unavailable }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    return .failed(String(localized: "App Store에서 구입을 확인하지 못했습니다."))
                }
                await transaction.finish()
                await refreshEntitlements()
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restorePurchases() async -> PremiumRestoreOutcome {
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
        await refreshEntitlements()
        return isPremium ? .restored : .nothingToRestore
    }

    private func loadProduct() async {
        do {
            let products = try await Product.products(for: productIDs)
            product =
                products.first { $0.id == PremiumEntitlement.monthlyProductID } ?? products.first
        } catch {
            // Offline or the store is down: keep what we had and let the
            // purchase button say the store is unavailable.
        }
        premiumOffer = product.flatMap(Self.offer(for:))
    }

    private func refreshEntitlements() async {
        var entitlements: [PremiumEntitlementSnapshot] = []
        for await result in Transaction.currentEntitlements {
            entitlements.append(PremiumEntitlementSnapshot(result))
        }
        isPremium = PremiumEntitlement.isPremium(entitlements, productIDs: productIDs)
    }

    private func handle(_ update: VerificationResult<Transaction>) async {
        if case .verified(let transaction) = update {
            await transaction.finish()
        }
        await refreshEntitlements()
    }

    private static func offer(for product: Product) -> PremiumOffer? {
        guard let subscription = product.subscription else { return nil }
        let period: PremiumOffer.Period
        switch subscription.subscriptionPeriod.unit {
        case .day: period = .day
        case .week: period = .week
        case .month: period = .month
        case .year: period = .year
        @unknown default: period = .month
        }
        return PremiumOffer(
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            period: period,
            periodLength: subscription.subscriptionPeriod.value
        )
    }
}
