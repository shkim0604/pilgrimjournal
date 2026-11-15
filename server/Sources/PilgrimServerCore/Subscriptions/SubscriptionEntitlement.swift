import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// The one answer to "may this user use groups?" (design.md 12절). `GET /me`,
/// `GET /me/entitlement`, `POST /subscriptions/verify`, the group 402 gate and the invite
/// preview's `requiresSubscription` must all come from here so they never disagree:
///
/// - `SUBSCRIPTION_REQUIRED=false`: everyone is entitled (`active = true`); the status of a
///   purchase, if any, is still reported.
/// - `SUBSCRIPTION_REQUIRED=true`: entitled when any of the user's rows passes
///   `EntitlementPolicy.isActive` (active or grace, and `expires_at > now`).
///
/// The reported row is the entitled one that lasts longest, else the one that ended last.
public enum SubscriptionEntitlement {
    /// What the policy needs from a `subscriptions` row.
    public struct Row: Sendable, Equatable {
        public var status: SubscriptionStatus
        public var expiresAt: Date?
        public var productID: String?

        public init(status: SubscriptionStatus, expiresAt: Date?, productID: String? = nil) {
            self.status = status
            self.expiresAt = expiresAt
            self.productID = productID
        }

        init(_ subscription: AppStoreSubscription) {
            self.init(
                status: subscription.status, expiresAt: subscription.expiresAt,
                productID: subscription.productID)
        }
    }

    // MARK: - Pure

    /// Whether any row is a paid, unexpired subscription, ignoring `SUBSCRIPTION_REQUIRED`.
    public static func hasActiveSubscription(_ rows: [Row], now: Date) -> Bool {
        rows.contains {
            EntitlementPolicy.isActive(status: $0.status, expiresAt: $0.expiresAt, now: now)
        }
    }

    /// The row `EntitlementResponse` reports, or nil without rows.
    static func reportedRow(_ rows: [Row], now: Date) -> Row? {
        func later(_ a: Row, _ b: Row) -> Bool {
            (a.expiresAt ?? .distantPast) > (b.expiresAt ?? .distantPast)
        }
        let active = rows.filter {
            EntitlementPolicy.isActive(status: $0.status, expiresAt: $0.expiresAt, now: now)
        }
        return active.sorted(by: later).first ?? rows.sorted(by: later).first
    }

    public static func response(rows: [Row], subscriptionRequired: Bool, now: Date)
        -> EntitlementResponse
    {
        guard let row = reportedRow(rows, now: now) else {
            return subscriptionRequired
                ? EntitlementResponse(subscriptionRequired: true, active: false, status: .none)
                : .notRequired
        }
        let subscribed = EntitlementPolicy.isActive(
            status: row.status, expiresAt: row.expiresAt, now: now)
        return EntitlementResponse(
            subscriptionRequired: subscriptionRequired, active: subscribed || !subscriptionRequired,
            status: row.status, productId: row.productID, expiresAt: row.expiresAt)
    }

    // MARK: - Database

    public static func rows(for userID: UUID, on db: any Database) async throws -> [Row] {
        try await AppStoreSubscription.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map(Row.init)
    }

    /// `EntitlementResponse` for `GET /me`, `GET /me/entitlement` and `POST /subscriptions/verify`.
    public static func response(
        for userID: UUID, subscriptionRequired: Bool, on db: any Database, now: Date = Date()
    ) async throws -> EntitlementResponse {
        response(
            rows: try await rows(for: userID, on: db), subscriptionRequired: subscriptionRequired,
            now: now)
    }

    /// Whether `userID` may use the group API: always while `SUBSCRIPTION_REQUIRED=false`.
    /// Does not read the database then.
    public static func isEntitled(
        _ userID: UUID, subscriptionRequired: Bool, on db: any Database, now: Date = Date()
    ) async throws -> Bool {
        guard subscriptionRequired else { return true }
        return hasActiveSubscription(try await rows(for: userID, on: db), now: now)
    }

    /// `InvitePreviewResponse.requiresSubscription`: the app must show the subscription screen.
    public static func requiresSubscription(
        _ userID: UUID, subscriptionRequired: Bool, on db: any Database, now: Date = Date()
    ) async throws -> Bool {
        try await !isEntitled(userID, subscriptionRequired: subscriptionRequired, on: db, now: now)
    }

    /// Throws 402 `SUBSCRIPTION_REQUIRED` unless `isEntitled`.
    public static func ensureEntitled(
        _ userID: UUID, subscriptionRequired: Bool, on db: any Database, now: Date = Date()
    ) async throws {
        guard
            try await isEntitled(
                userID, subscriptionRequired: subscriptionRequired, on: db, now: now)
        else {
            throw APIError(code: .subscriptionRequired, message: "subscription required")
        }
    }
}

/// 402 `SUBSCRIPTION_REQUIRED` for routes that need a subscription while
/// `SUBSCRIPTION_REQUIRED=true` (after `UserAuthMiddleware`). A no-op while the flag is off.
public struct SubscriptionRequiredMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        try await SubscriptionEntitlement.ensureEntitled(
            try request.userID, subscriptionRequired: request.pilgrimConfig.subscriptionRequired,
            on: request.db)
        return try await next.respond(to: request)
    }
}
