import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// `POST /subscriptions/verify` and `POST /api/appstore/notifications` (design.md 12절), and the
/// row upsert the worker's re-check shares.
enum SubscriptionService {
    /// Products this server records. Other products' transactions are refused (verify) or only
    /// logged (notifications).
    static let products: Set<String> = [SubscriptionProduct.groupsMonthly]

    // MARK: - Verify

    /// Verifies a StoreKit 2 transaction the signed-in `caller` sent, binds it to them and
    /// returns their entitlement.
    ///
    /// - 422 `SUBSCRIPTION_INVALID`: the JWS does not verify, is for another app or bundle than
    ///   `request.bundleId`, or for another product.
    /// - 409 `SUBSCRIPTION_OWNED_BY_OTHER_USER`: its `appAccountToken` is another user, or the
    ///   original transaction is already bound to another user.
    static func verify(
        _ request: VerifySubscriptionRequest, caller: UUID, verifier: AppStoreSignedDataVerifier,
        subscriptionRequired: Bool, on db: any Database, now: Date = Date()
    ) async throws -> EntitlementResponse {
        let transaction: AppStoreTransaction
        do {
            transaction = try await verifier.verifyTransaction(
                request.signedTransaction, expectedBundleID: request.bundleId)
        } catch let error as AppStoreVerificationError {
            throw APIError(code: .subscriptionInvalid, message: error.description)
        }
        guard products.contains(transaction.productID) else {
            throw APIError(
                code: .subscriptionInvalid,
                message: "unknown product \(transaction.productID)")
        }
        try await db.transaction { tx in
            _ = try await upsert(
                transaction, as: .device, owner: .verifiedBy(caller), on: tx, now: now)
        }
        return try await SubscriptionEntitlement.response(
            for: caller, subscriptionRequired: subscriptionRequired, on: db, now: now)
    }

    // MARK: - Notifications

    enum NotificationOutcome: Equatable, Sendable {
        /// The `notificationUUID` was handled before; nothing changed.
        case duplicate
        /// Logged in `appstore_notifications` only (`TEST`, another product, no transaction, or
        /// older than a notification already handled).
        case recorded
        /// Logged and applied to the subscription row.
        case applied
    }

    /// Verifies and applies one App Store Server Notification V2. Throws 400 `INVALID_REQUEST`
    /// when the payload or its nested signed data does not verify (Apple retries; a forged
    /// request changes nothing).
    static func receiveNotification(
        signedPayload: String, verifier: AppStoreSignedDataVerifier, on db: any Database,
        now: Date = Date()
    ) async throws -> NotificationOutcome {
        let (payload, transaction, renewal) = try await verifiedNotification(
            signedPayload, verifier: verifier)
        let effect: SubscriptionTransition.NotificationEffect =
            if let transaction, !products.contains(transaction.productID) {
                .recordOnly
            } else {
                SubscriptionTransition.effect(
                    ofNotificationType: payload.notificationType, subtype: payload.subtype)
            }

        return try await db.transaction { tx in
            guard try await record(payload, transaction: transaction, on: tx, now: now) else {
                return .duplicate
            }
            guard let transaction else { return .recorded }
            let update: SubscriptionUpdate
            switch effect {
            case .recordOnly:
                return .recorded
            case .gracePeriod:
                update = .notification(
                    status: .gracePeriod, entitlementEnd: renewal?.gracePeriodExpiresDate)
            case .apply(let stated):
                update = stated
            }
            if let signedDate = payload.signedDate,
                try await hasNewerNotification(
                    than: signedDate, for: transaction.originalTransactionID,
                    excluding: payload.notificationUUID, on: tx)
            {
                return .recorded
            }
            _ = try await upsert(
                transaction, as: update, owner: .fromNotification, on: tx, now: now)
            return .applied
        }
    }

    /// The notification and its nested signed transaction and renewal info, all verified.
    private static func verifiedNotification(
        _ signedPayload: String, verifier: AppStoreSignedDataVerifier
    ) async throws -> (AppStoreNotificationPayload, AppStoreTransaction?, AppStoreRenewalInfo?) {
        do {
            let payload = try await verifier.verifyNotification(signedPayload)
            var transaction: AppStoreTransaction?
            if let jws = payload.data?.signedTransactionInfo {
                transaction = try await verifier.verifyTransaction(
                    jws, expectedBundleID: payload.appBundleID)
            }
            var renewal: AppStoreRenewalInfo?
            if let jws = payload.data?.signedRenewalInfo {
                renewal = try await verifier.verifyRenewalInfo(jws)
            }
            return (payload, transaction, renewal)
        } catch let error as AppStoreVerificationError {
            throw APIError.invalidRequest(error.description)
        }
    }

    /// Inserts the `appstore_notifications` row; false when this `notificationUUID` exists.
    private static func record(
        _ payload: AppStoreNotificationPayload, transaction: AppStoreTransaction?,
        on db: any Database, now: Date
    ) async throws -> Bool {
        let sql = try PushOutbox.sqlDatabase(db)
        let inserted = try await sql.raw(
            """
            INSERT INTO appstore_notifications
                (id, notification_type, subtype, original_transaction_id, signed_date, received_at)
            VALUES (\(bind: payload.notificationUUID), \(bind: payload.notificationType), \
            \(bind: payload.subtype), \(bind: transaction?.originalTransactionID), \
            \(bind: payload.signedDate), \(bind: now))
            ON CONFLICT (id) DO NOTHING
            RETURNING id
            """
        ).first()
        return inserted != nil
    }

    /// Apple may deliver notifications out of order; an older one must not undo a newer one.
    private static func hasNewerNotification(
        than signedDate: Date, for originalTransactionID: String, excluding id: UUID,
        on db: any Database
    ) async throws -> Bool {
        let sql = try PushOutbox.sqlDatabase(db)
        return try await sql.raw(
            """
            SELECT id FROM appstore_notifications
             WHERE original_transaction_id = \(bind: originalTransactionID)
               AND id <> \(bind: id)
               AND notification_type <> 'TEST'
               AND signed_date > \(bind: signedDate)
             LIMIT 1
            """
        ).first() != nil
    }

    // MARK: - Upsert

    enum OwnerRule: Sendable, Equatable {
        /// `POST /subscriptions/verify` by this user (409 rules of `SubscriptionOwnership`).
        case verifiedBy(UUID)
        /// A notification: keep the owner, or adopt the `appAccountToken` user.
        case fromNotification
        /// The worker re-check: never changes the owner.
        case keep
    }

    /// Creates or updates the row for `transaction.originalTransactionID` inside the caller's
    /// transaction, holding the row lock while it decides.
    @discardableResult
    static func upsert(
        _ transaction: AppStoreTransaction, as update: SubscriptionUpdate, owner rule: OwnerRule,
        checkedAt: Date? = nil, on db: any Database, now: Date
    ) async throws -> AppStoreSubscription {
        // Two attempts: a concurrent first insert of the same original transaction makes ours
        // a no-op, and the second pass updates the row it created.
        for _ in 0..<2 {
            if let row = try await lockedRow(transaction.originalTransactionID, on: db) {
                let owner = try await resolveOwner(
                    rule, existing: row.$user.id, transaction: transaction, on: db)
                let state = SubscriptionTransition.next(
                    state(of: row), applying: transaction, as: update, now: now)
                write(state, to: row)
                row.$user.id = owner
                if let checkedAt { row.lastCheckedAt = checkedAt }
                try await row.save(on: db)
                return row
            }
            let owner = try await resolveOwner(
                rule, existing: nil, transaction: transaction, on: db)
            let state = SubscriptionTransition.next(
                nil, applying: transaction, as: update, now: now)
            if let id = try await insert(
                state, originalTransactionID: transaction.originalTransactionID, owner: owner,
                checkedAt: checkedAt, on: db, now: now),
                let row = try await AppStoreSubscription.find(id, on: db)
            {
                return row
            }
        }
        throw APIError(code: .internal, message: "subscription upsert did not settle")
    }

    private static func resolveOwner(
        _ rule: OwnerRule, existing: UUID?, transaction: AppStoreTransaction, on db: any Database
    ) async throws -> UUID? {
        switch rule {
        case .verifiedBy(let caller):
            var tokenUserExists = false
            if let token = transaction.appAccountToken, token != caller {
                tokenUserExists = try await User.find(token, on: db) != nil
            }
            return try SubscriptionOwnership.ownerForVerify(
                caller: caller, existingOwner: existing,
                appAccountToken: transaction.appAccountToken, tokenUserExists: tokenUserExists)
        case .fromNotification:
            var tokenUserExists = false
            if existing == nil, let token = transaction.appAccountToken {
                tokenUserExists = try await User.find(token, on: db) != nil
            }
            return SubscriptionOwnership.ownerForNotification(
                existingOwner: existing, appAccountToken: transaction.appAccountToken,
                tokenUserExists: tokenUserExists)
        case .keep:
            return existing
        }
    }

    static func lockedRow(_ originalTransactionID: String, on db: any Database) async throws
        -> AppStoreSubscription?
    {
        let sql = try PushOutbox.sqlDatabase(db)
        guard
            let row = try await sql.raw(
                """
                SELECT id FROM subscriptions
                 WHERE original_transaction_id = \(bind: originalTransactionID)
                 FOR UPDATE
                """
            ).first()
        else { return nil }
        return try await AppStoreSubscription.find(
            try row.decode(column: "id", as: UUID.self), on: db)
    }

    private static func insert(
        _ state: SubscriptionState, originalTransactionID: String, owner: UUID?,
        checkedAt: Date?, on db: any Database, now: Date
    ) async throws -> UUID? {
        let sql = try PushOutbox.sqlDatabase(db)
        let row = try await sql.raw(
            """
            INSERT INTO subscriptions
                (id, user_id, original_transaction_id, product_id, status, expires_at,
                 environment, bundle_id, app_account_token, last_transaction_id, storefront,
                 removal_processed_at, last_checked_at, created_at, updated_at)
            VALUES (\(bind: UUID()), \(bind: owner), \(bind: originalTransactionID), \
            \(bind: state.productID), \(bind: state.status.rawValue), \(bind: state.expiresAt), \
            \(bind: state.environment.rawValue), \(bind: state.bundleID), \
            \(bind: state.appAccountToken), \(bind: state.lastTransactionID), \
            \(bind: state.storefront), \(bind: state.removalProcessedAt), \(bind: checkedAt), \
            \(bind: now), \(bind: now))
            ON CONFLICT (original_transaction_id) DO NOTHING
            RETURNING id
            """
        ).first()
        return try row?.decode(column: "id", as: UUID.self)
    }

    static func state(of row: AppStoreSubscription) -> SubscriptionState {
        SubscriptionState(
            productID: row.productID, status: row.status, expiresAt: row.expiresAt,
            environment: row.environment, bundleID: row.bundleID,
            appAccountToken: row.appAccountToken, lastTransactionID: row.lastTransactionID,
            storefront: row.storefront, removalProcessedAt: row.removalProcessedAt)
    }

    private static func write(_ state: SubscriptionState, to row: AppStoreSubscription) {
        row.productID = state.productID
        row.status = state.status
        row.expiresAt = state.expiresAt
        row.environment = state.environment
        row.bundleID = state.bundleID
        row.appAccountToken = state.appAccountToken
        row.lastTransactionID = state.lastTransactionID
        row.storefront = state.storefront
        row.removalProcessedAt = state.removalProcessedAt
    }
}
