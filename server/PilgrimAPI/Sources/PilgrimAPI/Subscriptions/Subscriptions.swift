import Foundation

public enum SubscriptionStatus: String, Sendable, Codable, CaseIterable {
    case active, gracePeriod, billingRetry, expired, revoked, none
}

/// `GET /me/entitlement`, `POST /subscriptions/verify`, and `MeResponse.entitlement`.
public struct EntitlementResponse: Equatable, Sendable, Codable {
    /// The server's `SUBSCRIPTION_REQUIRED`. false → everyone counts as subscribed.
    public var subscriptionRequired: Bool
    public var active: Bool
    public var status: SubscriptionStatus
    public var productId: String?
    public var expiresAt: Date?

    public init(
        subscriptionRequired: Bool, active: Bool, status: SubscriptionStatus,
        productId: String? = nil, expiresAt: Date? = nil
    ) {
        self.subscriptionRequired = subscriptionRequired
        self.active = active
        self.status = status
        self.productId = productId
        self.expiresAt = expiresAt
    }

    /// What the server answers while `SUBSCRIPTION_REQUIRED=false` for a user with no purchase.
    public static let notRequired = EntitlementResponse(
        subscriptionRequired: false, active: true, status: .none)
}

/// `POST /subscriptions/verify`: a StoreKit 2 `Transaction.jwsRepresentation`.
public struct VerifySubscriptionRequest: Equatable, Sendable, Codable {
    public var signedTransaction: String
    public var bundleId: String

    public init(signedTransaction: String, bundleId: String) {
        self.signedTransaction = signedTransaction
        self.bundleId = bundleId
    }
}

/// `POST /api/appstore/notifications` (App Store Server Notifications V2, outside v1).
public struct AppStoreNotificationRequest: Equatable, Sendable, Codable {
    public var signedPayload: String

    public init(signedPayload: String) {
        self.signedPayload = signedPayload
    }
}

public enum SubscriptionProduct {
    /// Auto-renewing monthly group subscription.
    public static let groupsMonthly = "com.dhouse.PilgrimJournal.groups.monthly"
}

/// `EntitlementPolicy`: subscribed when the status is active or in grace, and not past expiry.
public enum EntitlementPolicy {
    public static func isActive(status: SubscriptionStatus, expiresAt: Date?, now: Date) -> Bool {
        guard status == .active || status == .gracePeriod, let expiresAt else { return false }
        return expiresAt > now
    }
}
