import Foundation
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Subscription routes that answer before touching Postgres: the webhook refuses unverifiable
/// payloads, the v1 routes need a session, and the worker loop is registered.
final class SubscriptionRouteTests: ServerTestCase {
    private var pki: AppStoreTestPKI!

    override func setUp() async throws {
        try await super.setUp()
        pki = try AppStoreTestPKI()
        app.subscriptionServices.verifier = pki.verifier
    }

    func testWebhookRefusesUnverifiedPayloads() async throws {
        let stranger = try AppStoreTestPKI()
        let forged = try stranger.sign(AppStoreTestPayloads.notification(type: "EXPIRED"))
        for payload in ["", "not.a.jws", forged] {
            let response = try await app.sendRequest(
                .POST, "/api/appstore/notifications",
                headers: ["Content-Type": "application/json"],
                body: ByteBuffer(
                    data: try PilgrimJSON.encode(
                        AppStoreNotificationRequest(signedPayload: payload)))
            )
            try assertError(response, .invalidRequest)
        }
    }

    func testWebhookRefusesNestedTransactionFromAnotherPKI() async throws {
        let stranger = try AppStoreTestPKI()
        let transaction = try stranger.sign(
            AppStoreTestPayloads.transaction(expires: Date().addingTimeInterval(86_400)))
        let signed = try pki.sign(
            AppStoreTestPayloads.notification(type: "DID_RENEW", signedTransaction: transaction))
        let response = try await send(
            .POST, "/api/appstore/notifications",
            json: AppStoreNotificationRequest(signedPayload: signed))
        try assertError(response, .invalidRequest)
    }

    func testWebhookRefusesABodyWithoutSignedPayload() async throws {
        let response = try await app.sendRequest(
            .POST, "/api/appstore/notifications", headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: #"{"payload":"x"}"#))
        try assertError(response, .invalidRequest)
    }

    func testWebhookNeedsNoClientHeader() async throws {
        // No X-Pilgrim-Client: still the webhook's own 400, not the v1 gate's 426.
        let response = try await app.sendRequest(
            .POST, "/api/appstore/notifications", headers: ["Content-Type": "application/json"],
            body: ByteBuffer(string: #"{"signedPayload":"x"}"#))
        try assertError(response, .invalidRequest)
    }

    func testV1RoutesNeedASession() async throws {
        let verify = try await send(
            .POST, "/api/v1/subscriptions/verify",
            json: VerifySubscriptionRequest(signedTransaction: "x", bundleId: BundleIDs.release))
        try assertError(verify, .unauthenticated)
        let entitlement = try await send(.GET, "/api/v1/me/entitlement")
        try assertError(entitlement, .unauthenticated)
    }

    func testWorkerLoopIsRegistered() {
        let job = app.workerJobs.jobs.first { $0.name == "subscriptions" }
        XCTAssertEqual(job?.lockKey, WorkerLockKey.subscriptions)
        // A 10-minute period that still beats within the health window.
        XCTAssertEqual(job?.interval, WorkerInterval.maximumTick)
    }

    func testFlagOffNeverReadsTheDatabase() async throws {
        // The test app's database is unreachable: any query would throw.
        let entitled = try await SubscriptionEntitlement.isEntitled(
            UUID(), subscriptionRequired: false, on: app.db)
        XCTAssertTrue(entitled)
        let requires = try await SubscriptionEntitlement.requiresSubscription(
            UUID(), subscriptionRequired: false, on: app.db)
        XCTAssertFalse(requires)
        try await SubscriptionEntitlement.ensureEntitled(
            UUID(), subscriptionRequired: false, on: app.db)
    }

    func testServicesWithoutInAppPurchaseKeyHaveNoStatusClient() throws {
        XCTAssertNil(app.subscriptionServices.statusClient)
    }
}
