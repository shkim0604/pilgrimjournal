import Foundation
import PilgrimAPI

/// The stored state of one `subscriptions` row, without the owner (see `SubscriptionOwnership`).
public struct SubscriptionState: Sendable, Equatable {
    public var productID: String
    public var status: SubscriptionStatus
    /// The end of the entitlement: the transaction's `expiresDate`, or the grace period end
    /// while `gracePeriod`.
    public var expiresAt: Date?
    public var environment: AppStoreSubscription.Environment
    public var bundleID: String
    public var appAccountToken: UUID?
    public var lastTransactionID: String?
    public var storefront: String?
    public var removalProcessedAt: Date?

    public init(
        productID: String, status: SubscriptionStatus, expiresAt: Date?,
        environment: AppStoreSubscription.Environment, bundleID: String,
        appAccountToken: UUID? = nil, lastTransactionID: String? = nil, storefront: String? = nil,
        removalProcessedAt: Date? = nil
    ) {
        self.productID = productID
        self.status = status
        self.expiresAt = expiresAt
        self.environment = environment
        self.bundleID = bundleID
        self.appAccountToken = appAccountToken
        self.lastTransactionID = lastTransactionID
        self.storefront = storefront
        self.removalProcessedAt = removalProcessedAt
    }
}

/// Where a verified transaction came from, which decides how much it may change.
public enum SubscriptionUpdate: Sendable, Equatable {
    /// `POST /subscriptions/verify`, and notifications that only report a setting change
    /// (`DID_CHANGE_RENEWAL_STATUS`, `DID_CHANGE_RENEWAL_PREF`, `OFFER_REDEEMED`, …). A newer
    /// transaction sets the status from itself; the same transaction only marks a revocation and
    /// otherwise keeps what notifications decided (a grace period, billing retry, expiry).
    case device
    /// A notification that states the status (`nil`: take it from the transaction, for
    /// `REFUND_REVERSED` and `RENEWAL_EXTENDED`). `entitlementEnd` replaces the transaction's
    /// `expiresDate` (the grace period end).
    case notification(status: SubscriptionStatus?, entitlementEnd: Date? = nil)
    /// The App Store Server API's current answer (the worker's re-check). Always applied.
    case statusCheck(status: SubscriptionStatus, entitlementEnd: Date? = nil)
}

/// Pure state transitions for one subscription (design.md 12절).
public enum SubscriptionTransition {
    /// The status a transaction implies by itself: revoked when it has a `revocationDate`,
    /// active until `expiresDate`, expired after.
    public static func impliedStatus(of transaction: AppStoreTransaction, now: Date)
        -> SubscriptionStatus
    {
        if transaction.revocationDate != nil { return .revoked }
        guard let expires = transaction.expiresDate, expires > now else { return .expired }
        return .active
    }

    /// Whether `transaction` belongs to an earlier period than `current`: a different
    /// transaction that ends before what is stored. Late or replayed data of that kind never
    /// changes the state (a delayed `EXPIRED` after a resubscription, an old JWS from a device).
    public static func isOlder(_ transaction: AppStoreTransaction, than current: SubscriptionState)
        -> Bool
    {
        guard transaction.transactionID != current.lastTransactionID,
            let stored = current.expiresAt
        else { return false }
        return (transaction.expiresDate ?? .distantPast) < stored
    }

    /// The row after applying `transaction` as `update`. `current == nil` creates the row.
    ///
    /// `removalProcessedAt` is cleared when the result is entitled again (active or grace), so a
    /// later expiry is handled again; otherwise it is kept, so expiry handling runs once.
    public static func next(
        _ current: SubscriptionState?, applying transaction: AppStoreTransaction,
        as update: SubscriptionUpdate, now: Date
    ) -> SubscriptionState {
        let implied = impliedStatus(of: transaction, now: now)
        let status: SubscriptionStatus
        var expiresAt = transaction.expiresDate
        var refreshesTransaction = true

        switch update {
        case .statusCheck(let stated, let end):
            status = stated
            if let end { expiresAt = end }
        case .notification(let stated, let end):
            if let current, isOlder(transaction, than: current) { return current }
            status = stated ?? implied
            if let end { expiresAt = end }
        case .device:
            guard let current else {
                status = implied
                break
            }
            if isOlder(transaction, than: current) { return current }
            if transaction.transactionID == current.lastTransactionID {
                // Same period: notifications know more (grace, billing retry), except a refund
                // the device saw first.
                status = transaction.revocationDate != nil ? .revoked : current.status
                expiresAt = current.expiresAt
                refreshesTransaction = false
            } else {
                status = implied
            }
        }

        // The verifier only lets Production and Sandbox through; anything else keeps the row's.
        let environment =
            AppStoreSubscription.Environment(rawValue: transaction.environment)
            ?? current?.environment ?? .sandbox
        var state =
            current
            ?? SubscriptionState(
                productID: transaction.productID, status: status, expiresAt: expiresAt,
                environment: environment, bundleID: transaction.bundleID)
        state.status = status
        state.expiresAt = expiresAt
        if refreshesTransaction {
            state.productID = transaction.productID
            state.environment = environment
            state.bundleID = transaction.bundleID
            state.lastTransactionID = transaction.transactionID
            if let storefront = transaction.storefront { state.storefront = storefront }
        }
        if let token = transaction.appAccountToken { state.appAccountToken = token }
        if status == .active || status == .gracePeriod { state.removalProcessedAt = nil }
        return state
    }

    // MARK: - Notifications

    /// What a notification type does (design.md 12절).
    public enum NotificationEffect: Sendable, Equatable {
        /// Recorded in `appstore_notifications` only (`TEST`, other products, no transaction).
        case recordOnly
        case apply(SubscriptionUpdate)
        /// `DID_FAIL_TO_RENEW` / `GRACE_PERIOD`: grace until the renewal info's
        /// `gracePeriodExpiresDate`.
        case gracePeriod
    }

    public static func effect(ofNotificationType type: String, subtype: String?)
        -> NotificationEffect
    {
        switch type {
        case "TEST": .recordOnly
        case "SUBSCRIBED", "DID_RENEW": .apply(.notification(status: .active))
        case "DID_FAIL_TO_RENEW":
            subtype == "GRACE_PERIOD"
                ? .gracePeriod : .apply(.notification(status: .billingRetry))
        // The grace period ended without a renewal; Apple keeps retrying billing.
        case "GRACE_PERIOD_EXPIRED": .apply(.notification(status: .billingRetry))
        case "EXPIRED": .apply(.notification(status: .expired))
        case "REFUND", "REVOKE": .apply(.notification(status: .revoked))
        case "REFUND_REVERSED", "RENEWAL_EXTENDED": .apply(.notification(status: nil))
        // DID_CHANGE_RENEWAL_STATUS, DID_CHANGE_RENEWAL_PREF, OFFER_REDEEMED, PRICE_INCREASE, …
        default: .apply(.device)
        }
    }

    /// Maps the App Store Server API `status` (1…5).
    public static func status(fromAppStoreStatus code: Int) -> SubscriptionStatus? {
        switch code {
        case 1: .active
        case 2: .expired
        case 3: .billingRetry
        case 4: .gracePeriod
        case 5: .revoked
        default: nil
        }
    }
}

/// Who a subscription row belongs to (design.md 12절: `appAccountToken = 서버 사용자 ID`).
public enum SubscriptionOwnership {
    /// The owner after `caller` verifies a transaction. Throws 409
    /// `SUBSCRIPTION_OWNED_BY_OTHER_USER` when the purchase names another existing user in its
    /// `appAccountToken` or the row is already bound to someone else. A token whose account was
    /// deleted names no one, so the person's new account can claim the purchase they still pay.
    public static func ownerForVerify(
        caller: UUID, existingOwner: UUID?, appAccountToken: UUID?, tokenUserExists: Bool
    ) throws -> UUID {
        if let appAccountToken, appAccountToken != caller, tokenUserExists {
            throw APIError(
                code: .subscriptionOwnedByOtherUser,
                message: "the purchase belongs to another account")
        }
        if let existingOwner, existingOwner != caller {
            throw APIError(
                code: .subscriptionOwnedByOtherUser,
                message: "the subscription is linked to another account")
        }
        return caller
    }

    /// The owner after a notification: an existing owner stays; an unowned row takes the
    /// `appAccountToken` user when that account exists.
    public static func ownerForNotification(
        existingOwner: UUID?, appAccountToken: UUID?, tokenUserExists: Bool
    ) -> UUID? {
        if let existingOwner { return existingOwner }
        guard let appAccountToken, tokenUserExists else { return nil }
        return appAccountToken
    }
}
