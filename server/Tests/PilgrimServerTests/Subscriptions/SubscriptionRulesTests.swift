import Crypto
import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

/// Pure subscription rules: state transitions (2.3.1, 2.3.2), ownership, the entitlement answer
/// (2.3.3) and the App Store Server API token (2.3.4).
final class SubscriptionRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var day: TimeInterval { 86_400 }

    private func transaction(
        id: String = "t1", expires: Date?, revoked: Date? = nil, token: UUID? = nil,
        environment: String = "Production"
    ) -> AppStoreTransaction {
        AppStoreTransaction(
            originalTransactionID: "o1", transactionID: id, bundleID: BundleIDs.release,
            productID: SubscriptionProduct.groupsMonthly, environment: environment,
            expiresDate: expires, revocationDate: revoked, appAccountToken: token,
            storefront: "KOR")
    }

    private func state(
        _ status: SubscriptionStatus, expires: Date?, lastTransaction: String? = "t1",
        removalProcessedAt: Date? = nil
    ) -> SubscriptionState {
        SubscriptionState(
            productID: SubscriptionProduct.groupsMonthly, status: status, expiresAt: expires,
            environment: .production, bundleID: BundleIDs.release,
            lastTransactionID: lastTransaction, removalProcessedAt: removalProcessedAt)
    }

    // MARK: - Implied status

    func testImpliedStatus() {
        XCTAssertEqual(
            SubscriptionTransition.impliedStatus(
                of: transaction(expires: now.addingTimeInterval(1)), now: now), .active)
        XCTAssertEqual(
            SubscriptionTransition.impliedStatus(of: transaction(expires: now), now: now),
            .expired)
        XCTAssertEqual(
            SubscriptionTransition.impliedStatus(of: transaction(expires: nil), now: now),
            .expired)
        XCTAssertEqual(
            SubscriptionTransition.impliedStatus(
                of: transaction(expires: now.addingTimeInterval(day), revoked: now), now: now),
            .revoked)
    }

    // MARK: - Device (verify)

    func testFirstVerifyCreatesRowFromTransaction() {
        let token = UUID()
        let expires = now.addingTimeInterval(30 * day)
        let created = SubscriptionTransition.next(
            nil, applying: transaction(expires: expires, token: token), as: .device, now: now)
        XCTAssertEqual(created.status, .active)
        XCTAssertEqual(created.expiresAt, expires)
        XCTAssertEqual(created.lastTransactionID, "t1")
        XCTAssertEqual(created.appAccountToken, token)
        XCTAssertEqual(created.environment, .production)
        XCTAssertEqual(created.storefront, "KOR")

        let sandbox = SubscriptionTransition.next(
            nil, applying: transaction(expires: expires, environment: "Sandbox"), as: .device,
            now: now)
        XCTAssertEqual(sandbox.environment, .sandbox)
    }

    func testVerifyOfNewerTransactionRenews() {
        let current = state(.expired, expires: now.addingTimeInterval(-day))
        let renewed = SubscriptionTransition.next(
            current, applying: transaction(id: "t2", expires: now.addingTimeInterval(29 * day)),
            as: .device, now: now)
        XCTAssertEqual(renewed.status, .active)
        XCTAssertEqual(renewed.lastTransactionID, "t2")
    }

    func testVerifyOfSameTransactionKeepsNotificationState() {
        // In grace: the device still holds the transaction that ended yesterday.
        let graceEnd = now.addingTimeInterval(5 * day)
        let grace = state(.gracePeriod, expires: graceEnd)
        let after = SubscriptionTransition.next(
            grace, applying: transaction(expires: now.addingTimeInterval(-day)), as: .device,
            now: now)
        XCTAssertEqual(after, grace)

        let retry = state(.billingRetry, expires: now.addingTimeInterval(-day))
        XCTAssertEqual(
            SubscriptionTransition.next(
                retry, applying: transaction(expires: now.addingTimeInterval(-day)),
                as: .device, now: now), retry)
    }

    func testVerifyOfSameTransactionMarksRevocation() {
        let active = state(.active, expires: now.addingTimeInterval(day))
        let after = SubscriptionTransition.next(
            active,
            applying: transaction(expires: now.addingTimeInterval(day), revoked: now),
            as: .device, now: now)
        XCTAssertEqual(after.status, .revoked)
    }

    func testVerifyOfOlderTransactionChangesNothing() {
        let current = state(
            .active, expires: now.addingTimeInterval(20 * day), lastTransaction: "t2")
        let replayed = SubscriptionTransition.next(
            current, applying: transaction(id: "t1", expires: now.addingTimeInterval(-10 * day)),
            as: .device, now: now)
        XCTAssertEqual(replayed, current)
    }

    func testAppAccountTokenIsKeptWhenALaterTransactionHasNone() {
        let token = UUID()
        var current = state(.active, expires: now.addingTimeInterval(day))
        current.appAccountToken = token
        let after = SubscriptionTransition.next(
            current, applying: transaction(id: "t2", expires: now.addingTimeInterval(31 * day)),
            as: .device, now: now)
        XCTAssertEqual(after.appAccountToken, token)
    }

    // MARK: - Notifications

    func testNotificationEffects() {
        typealias T = SubscriptionTransition
        XCTAssertEqual(T.effect(ofNotificationType: "TEST", subtype: nil), .recordOnly)
        XCTAssertEqual(
            T.effect(ofNotificationType: "SUBSCRIBED", subtype: "INITIAL_BUY"),
            .apply(.notification(status: .active)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "SUBSCRIBED", subtype: "RESUBSCRIBE"),
            .apply(.notification(status: .active)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "DID_RENEW", subtype: nil),
            .apply(.notification(status: .active)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD"),
            .gracePeriod)
        XCTAssertEqual(
            T.effect(ofNotificationType: "DID_FAIL_TO_RENEW", subtype: nil),
            .apply(.notification(status: .billingRetry)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "GRACE_PERIOD_EXPIRED", subtype: nil),
            .apply(.notification(status: .billingRetry)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "EXPIRED", subtype: "VOLUNTARY"),
            .apply(.notification(status: .expired)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "REFUND", subtype: nil),
            .apply(.notification(status: .revoked)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "REVOKE", subtype: nil),
            .apply(.notification(status: .revoked)))
        XCTAssertEqual(
            T.effect(ofNotificationType: "REFUND_REVERSED", subtype: nil),
            .apply(.notification(status: nil)))
        XCTAssertEqual(
            T.effect(
                ofNotificationType: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED"),
            .apply(.device))
        XCTAssertEqual(
            T.effect(ofNotificationType: "SOMETHING_NEW", subtype: nil), .apply(.device))
    }

    func testNotificationStatusesApply() {
        let active = state(.active, expires: now.addingTimeInterval(-day))
        let lapsed = transaction(expires: now.addingTimeInterval(-day))
        for status: SubscriptionStatus in [.billingRetry, .expired, .revoked] {
            XCTAssertEqual(
                SubscriptionTransition.next(
                    active, applying: lapsed, as: .notification(status: status), now: now
                ).status, status)
        }
    }

    func testGracePeriodUsesGraceEndAsExpiry() {
        let graceEnd = now.addingTimeInterval(16 * day)
        let after = SubscriptionTransition.next(
            state(.active, expires: now.addingTimeInterval(-day)),
            applying: transaction(expires: now.addingTimeInterval(-day)),
            as: .notification(status: .gracePeriod, entitlementEnd: graceEnd), now: now)
        XCTAssertEqual(after.status, .gracePeriod)
        XCTAssertEqual(after.expiresAt, graceEnd)
        XCTAssertTrue(
            EntitlementPolicy.isActive(status: after.status, expiresAt: after.expiresAt, now: now))

        // The grace period then ends on the same transaction: applied, not mistaken for an
        // older period although its expiry is before the stored grace end.
        let ended = SubscriptionTransition.next(
            after, applying: transaction(expires: now.addingTimeInterval(-day)),
            as: .notification(status: .billingRetry), now: now)
        XCTAssertEqual(ended.status, .billingRetry)
        XCTAssertEqual(ended.expiresAt, now.addingTimeInterval(-day))
    }

    func testLateNotificationForAnEarlierPeriodIsIgnored() {
        // Resubscribed (t2) before the EXPIRED of the old period (t1) arrived.
        let resubscribed = state(
            .active, expires: now.addingTimeInterval(30 * day), lastTransaction: "t2")
        let late = SubscriptionTransition.next(
            resubscribed, applying: transaction(id: "t1", expires: now.addingTimeInterval(-day)),
            as: .notification(status: .expired), now: now)
        XCTAssertEqual(late, resubscribed)
    }

    func testRefundReversedRestoresFromTransaction() {
        let revoked = state(.revoked, expires: now.addingTimeInterval(10 * day))
        let restored = SubscriptionTransition.next(
            revoked, applying: transaction(expires: now.addingTimeInterval(10 * day)),
            as: .notification(status: nil), now: now)
        XCTAssertEqual(restored.status, .active)
    }

    func testStatusCheckIsAuthoritative() {
        let current = state(
            .active, expires: now.addingTimeInterval(20 * day), lastTransaction: "t2")
        let checked = SubscriptionTransition.next(
            current, applying: transaction(id: "t1", expires: now.addingTimeInterval(-day)),
            as: .statusCheck(status: .expired), now: now)
        XCTAssertEqual(checked.status, .expired)
        XCTAssertEqual(checked.lastTransactionID, "t1")
    }

    func testRemovalMarkerClearsOnlyWhenEntitledAgain() {
        let processed = now.addingTimeInterval(-day)
        let removed = state(
            .expired, expires: now.addingTimeInterval(-2 * day), removalProcessedAt: processed)

        let stillLapsed = SubscriptionTransition.next(
            removed, applying: transaction(expires: now.addingTimeInterval(-2 * day)),
            as: .notification(status: .revoked), now: now)
        XCTAssertEqual(stillLapsed.removalProcessedAt, processed, "expiry is handled once")

        let resubscribed = SubscriptionTransition.next(
            removed, applying: transaction(id: "t2", expires: now.addingTimeInterval(30 * day)),
            as: .notification(status: .active), now: now)
        XCTAssertNil(resubscribed.removalProcessedAt, "a later expiry is handled again")
    }

    func testAppStoreStatusCodes() {
        XCTAssertEqual(SubscriptionTransition.status(fromAppStoreStatus: 1), .active)
        XCTAssertEqual(SubscriptionTransition.status(fromAppStoreStatus: 2), .expired)
        XCTAssertEqual(SubscriptionTransition.status(fromAppStoreStatus: 3), .billingRetry)
        XCTAssertEqual(SubscriptionTransition.status(fromAppStoreStatus: 4), .gracePeriod)
        XCTAssertEqual(SubscriptionTransition.status(fromAppStoreStatus: 5), .revoked)
        XCTAssertNil(SubscriptionTransition.status(fromAppStoreStatus: 0))
    }

    func testStatusResponseFindsTheOriginalTransaction() throws {
        let json = """
            {"environment":"Sandbox","bundleId":"com.dhouse.PilgrimJournal","appAppleId":1,
             "data":[{"subscriptionGroupIdentifier":"1","lastTransactions":[
               {"originalTransactionId":"other","status":1,"signedTransactionInfo":"a"},
               {"originalTransactionId":"o1","status":4,"signedTransactionInfo":"b",
                "signedRenewalInfo":"c"}]}]}
            """
        let response = try JSONDecoder().decode(AppStoreStatusResponse.self, from: Data(json.utf8))
        let item = try XCTUnwrap(response.lastTransaction(for: "o1"))
        XCTAssertEqual(item.status, 4)
        XCTAssertEqual(item.signedRenewalInfo, "c")
        XCTAssertNil(response.lastTransaction(for: "missing"))
    }

    // MARK: - Ownership

    func testVerifyOwnership() throws {
        let caller = UUID()
        let other = UUID()
        XCTAssertEqual(
            try SubscriptionOwnership.ownerForVerify(
                caller: caller, existingOwner: nil, appAccountToken: nil, tokenUserExists: false),
            caller)
        XCTAssertEqual(
            try SubscriptionOwnership.ownerForVerify(
                caller: caller, existingOwner: caller, appAccountToken: caller,
                tokenUserExists: true), caller)
        // The token's account was deleted: it names no one.
        XCTAssertEqual(
            try SubscriptionOwnership.ownerForVerify(
                caller: caller, existingOwner: nil, appAccountToken: other,
                tokenUserExists: false), caller)
        for (existing, token) in [(other, nil), (nil, other), (caller, other), (other, caller)]
            as [(UUID?, UUID?)]
        {
            XCTAssertThrowsError(
                try SubscriptionOwnership.ownerForVerify(
                    caller: caller, existingOwner: existing, appAccountToken: token,
                    tokenUserExists: true)
            ) { error in
                XCTAssertEqual((error as? APIError)?.code, .subscriptionOwnedByOtherUser)
            }
        }
    }

    func testNotificationOwnership() {
        let owner = UUID()
        let token = UUID()
        XCTAssertEqual(
            SubscriptionOwnership.ownerForNotification(
                existingOwner: owner, appAccountToken: token, tokenUserExists: true), owner)
        XCTAssertEqual(
            SubscriptionOwnership.ownerForNotification(
                existingOwner: nil, appAccountToken: token, tokenUserExists: true), token)
        XCTAssertNil(
            SubscriptionOwnership.ownerForNotification(
                existingOwner: nil, appAccountToken: token, tokenUserExists: false))
        XCTAssertNil(
            SubscriptionOwnership.ownerForNotification(
                existingOwner: nil, appAccountToken: nil, tokenUserExists: true))
    }

    // MARK: - Entitlement

    func testEntitlementWhileNotRequired() {
        typealias E = SubscriptionEntitlement
        XCTAssertEqual(E.response(rows: [], subscriptionRequired: false, now: now), .notRequired)

        let lapsed = E.Row(
            status: .expired, expiresAt: now.addingTimeInterval(-day),
            productID: SubscriptionProduct.groupsMonthly)
        let response = E.response(rows: [lapsed], subscriptionRequired: false, now: now)
        XCTAssertFalse(response.subscriptionRequired)
        XCTAssertTrue(response.active, "everyone counts as subscribed while the flag is off")
        XCTAssertEqual(response.status, .expired)
        XCTAssertEqual(response.expiresAt, lapsed.expiresAt)
    }

    func testEntitlementWhileRequired() {
        typealias E = SubscriptionEntitlement
        XCTAssertEqual(
            E.response(rows: [], subscriptionRequired: true, now: now),
            EntitlementResponse(subscriptionRequired: true, active: false, status: .none))

        for (status, offset, active) in [
            (SubscriptionStatus.active, day, true), (.gracePeriod, day, true),
            (.active, -1, false), (.billingRetry, day, false), (.expired, day, false),
            (.revoked, day, false),
        ] {
            let row = E.Row(status: status, expiresAt: now.addingTimeInterval(offset))
            let response = E.response(rows: [row], subscriptionRequired: true, now: now)
            XCTAssertEqual(response.active, active, "\(status) \(offset)")
            XCTAssertEqual(response.status, status)
            XCTAssertEqual(E.hasActiveSubscription([row], now: now), active)
        }
        XCTAssertFalse(
            E.response(
                rows: [E.Row(status: .active, expiresAt: nil)], subscriptionRequired: true, now: now
            )
            .active)
    }

    func testEntitlementReportsTheBestRow() {
        typealias E = SubscriptionEntitlement
        let oldActive = E.Row(
            status: .active, expiresAt: now.addingTimeInterval(day), productID: "a")
        let laterExpired = E.Row(
            status: .expired, expiresAt: now.addingTimeInterval(9 * day), productID: "b")
        let longerActive = E.Row(
            status: .gracePeriod, expiresAt: now.addingTimeInterval(5 * day), productID: "c")
        let undated = E.Row(status: .billingRetry, expiresAt: nil, productID: "d")

        XCTAssertEqual(
            E.response(
                rows: [laterExpired, oldActive, undated], subscriptionRequired: true, now: now
            )
            .productId, "a", "an entitled row wins over a later-ending lapsed one")
        XCTAssertEqual(
            E.response(rows: [oldActive, longerActive], subscriptionRequired: true, now: now)
                .productId, "c")
        XCTAssertEqual(
            E.response(rows: [undated, laterExpired], subscriptionRequired: true, now: now)
                .productId, "b", "a row without expiry sorts last")
        XCTAssertEqual(
            E.response(rows: [undated], subscriptionRequired: true, now: now).status,
            .billingRetry)
    }

    // MARK: - App Store Server API token

    func testAPITokenIsSignedES256() throws {
        let key = P256.Signing.PrivateKey()
        let signer = try AppStoreAPITokenSigner(
            issuerID: "issuer-1", keyID: "KEY123",
            privateKeyPEM: key.pemRepresentation.replacingOccurrences(of: "\n", with: "\\n"))
        let token = try signer.token(bundleID: BundleIDs.release, now: now)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let header =
            try JSONSerialization.jsonObject(
                with: try unwrap(Data(base64URLEncoded: parts[0]))) as? [String: Any]
        XCTAssertEqual(header?["alg"] as? String, "ES256")
        XCTAssertEqual(header?["kid"] as? String, "KEY123")
        XCTAssertEqual(header?["typ"] as? String, "JWT")

        let claims =
            try JSONSerialization.jsonObject(
                with: try unwrap(Data(base64URLEncoded: parts[1]))) as? [String: Any]
        XCTAssertEqual(claims?["iss"] as? String, "issuer-1")
        XCTAssertEqual(claims?["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(claims?["bid"] as? String, BundleIDs.release)
        XCTAssertEqual(claims?["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(claims?["exp"] as? Int, 1_800_000_300)

        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try unwrap(Data(base64URLEncoded: parts[2])))
        XCTAssertTrue(
            key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    func testAPITokenSignerRefusesAnotherKeyType() {
        XCTAssertThrowsError(
            try AppStoreAPITokenSigner(issuerID: "i", keyID: "k", privateKeyPEM: "not a key"))
    }
}
