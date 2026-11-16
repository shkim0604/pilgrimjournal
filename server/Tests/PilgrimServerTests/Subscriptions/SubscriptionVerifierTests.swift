import Crypto
import Foundation
import PilgrimAPI
import X509
import XCTest

@testable import PilgrimServerCore

/// JWS and `x5c` chain verification for App Store signed data (2.3.1), with a test PKI built
/// in the test.
final class SubscriptionVerifierTests: XCTestCase {
    private let now = Date()

    func testEmbeddedAppleRootIsAppleRootCAG3() throws {
        let der = AppleRootCertificates.appleRootCAG3
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fingerprint, AppleRootCertificates.appleRootCAG3SHA256)

        let root = try Certificate(derEncoded: Array(der))
        XCTAssertEqual(root.subject, root.issuer)
        XCTAssertTrue(root.subject.description.contains("Apple Root CA - G3"))
        guard let key = P384.Signing.PublicKey(root.publicKey) else {
            return XCTFail("Apple Root CA - G3 is a P-384 certificate")
        }
        XCTAssertNotNil(key)
        // Self-signed: its own key verifies its signature.
        XCTAssertTrue(root.publicKey.isValidSignature(root.signature, for: root))
    }

    func testValidTransactionDecodes() async throws {
        let pki = try AppStoreTestPKI()
        let user = UUID()
        let expires = now.addingTimeInterval(30 * 86_400)
        let jws = try pki.sign(
            AppStoreTestPayloads.transaction(
                transactionID: "2000000000000009", expires: expires, appAccountToken: user,
                signed: now))

        let transaction = try await pki.verifier.verifyTransaction(
            jws, expectedBundleID: BundleIDs.release)
        XCTAssertEqual(transaction.originalTransactionID, "2000000000000001")
        XCTAssertEqual(transaction.transactionID, "2000000000000009")
        XCTAssertEqual(transaction.productID, SubscriptionProduct.groupsMonthly)
        XCTAssertEqual(transaction.environment, "Sandbox")
        XCTAssertEqual(transaction.appAccountToken, user)
        XCTAssertEqual(transaction.storefront, "KOR")
        XCTAssertEqual(
            try XCTUnwrap(transaction.expiresDate).timeIntervalSince1970,
            expires.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertNil(transaction.revocationDate)
    }

    func testBothBundlesAndBothEnvironmentsAreAccepted() async throws {
        let pki = try AppStoreTestPKI()
        for bundle in [BundleIDs.release, BundleIDs.debug] {
            for environment in ["Production", "Sandbox"] {
                let jws = try pki.sign(
                    AppStoreTestPayloads.transaction(
                        bundleID: bundle, environment: environment, expires: now))
                let transaction = try await pki.verifier.verifyTransaction(
                    jws, expectedBundleID: bundle)
                XCTAssertEqual(transaction.bundleID, bundle)
                XCTAssertEqual(transaction.environment, environment)
            }
        }
    }

    func testOtherAppsAndUnsignedEnvironmentsAreRefused() async throws {
        let pki = try AppStoreTestPKI()
        try await expectVerificationError(
            .wrongBundle("com.example.other"),
            pki.sign(AppStoreTestPayloads.transaction(bundleID: "com.example.other", expires: now)),
            pki)
        try await expectVerificationError(
            .wrongEnvironment("Xcode"),
            pki.sign(AppStoreTestPayloads.transaction(environment: "Xcode", expires: now)), pki)
        try await expectVerificationError(
            .wrongEnvironment("LocalTesting"),
            pki.sign(AppStoreTestPayloads.transaction(environment: "LocalTesting", expires: now)),
            pki)
        // Signed for the Debug app but sent as the Release one.
        let debug = try pki.sign(
            AppStoreTestPayloads.transaction(bundleID: BundleIDs.debug, expires: now))
        do {
            _ = try await pki.verifier.verifyTransaction(debug, expectedBundleID: BundleIDs.release)
            XCTFail("expected wrongBundle")
        } catch let error as AppStoreVerificationError {
            XCTAssertEqual(error, .wrongBundle(BundleIDs.debug))
        }
    }

    func testAnotherRootIsNotTrusted() async throws {
        let pki = try AppStoreTestPKI()
        let stranger = try AppStoreTestPKI()
        let jws = try stranger.sign(AppStoreTestPayloads.transaction(expires: now))
        await expectUntrusted(jws, pki.verifier)
        // The real Apple root does not trust the test PKI either.
        await expectUntrusted(jws, AppStoreSignedDataVerifier())
    }

    func testChainMustCarryAppleOIDs() async throws {
        var noWWDR = AppStoreTestPKI.Options()
        noWWDR.intermediateHasWWDROID = false
        let pkiWithoutWWDR = try AppStoreTestPKI(noWWDR)
        await expectUntrusted(
            try pkiWithoutWWDR.sign(AppStoreTestPayloads.transaction(expires: now)),
            pkiWithoutWWDR.verifier)

        var noReceipt = AppStoreTestPKI.Options()
        noReceipt.leafHasReceiptOID = false
        let pkiWithoutReceipt = try AppStoreTestPKI(noReceipt)
        await expectUntrusted(
            try pkiWithoutReceipt.sign(AppStoreTestPayloads.transaction(expires: now)),
            pkiWithoutReceipt.verifier)
    }

    func testIntermediateMustBeACertificateAuthority() async throws {
        var options = AppStoreTestPKI.Options()
        options.intermediateIsCA = false
        let pki = try AppStoreTestPKI(options)
        await expectUntrusted(
            try pki.sign(AppStoreTestPayloads.transaction(expires: now)), pki.verifier)
    }

    func testLeafMustBeValidAtSignedDate() async throws {
        var options = AppStoreTestPKI.Options()
        options.leafNotBefore = Date(timeIntervalSince1970: 1_600_000_000)
        options.leafNotAfter = Date(timeIntervalSince1970: 1_700_000_000)
        let pki = try AppStoreTestPKI(options)
        // Signed while the leaf was valid: accepted although the leaf has expired since, as
        // Apple's offline verification does.
        let old = Date(timeIntervalSince1970: 1_650_000_000)
        let accepted = try pki.sign(AppStoreTestPayloads.transaction(expires: old, signed: old))
        _ = try await pki.verifier.verifyTransaction(accepted)
        // Signed after the leaf expired.
        await expectUntrusted(
            try pki.sign(AppStoreTestPayloads.transaction(expires: now, signed: now)),
            pki.verifier)
    }

    func testChainMustBeLeafIntermediateRoot() async throws {
        let pki = try AppStoreTestPKI()
        let payload = AppStoreTestPayloads.transaction(expires: now)
        try await expectVerificationError(
            .unsupportedHeader("x5c must hold three certificates"),
            pki.sign(payload, chain: [pki.leaf, pki.intermediate]), pki)
        try await expectVerificationError(
            .unsupportedHeader("x5c must hold three certificates"),
            pki.sign(payload, chain: [pki.leaf, pki.intermediate, pki.root, pki.root]), pki)
        // The intermediate in the leaf's place: chain building cannot start at the signer.
        await expectUntrusted(
            try pki.sign(payload, chain: [pki.intermediate, pki.leaf, pki.root]), pki.verifier)
    }

    func testOnlyES256IsAccepted() async throws {
        let pki = try AppStoreTestPKI()
        let payload = AppStoreTestPayloads.transaction(expires: now)
        try await expectVerificationError(
            .unsupportedHeader("alg none"), pki.sign(payload, alg: "none"), pki)
        try await expectVerificationError(
            .unsupportedHeader("alg HS256"), pki.sign(payload, alg: "HS256"), pki)
    }

    func testTamperedPayloadOrSignatureIsRefused() async throws {
        let pki = try AppStoreTestPKI()
        let jws = try pki.sign(AppStoreTestPayloads.transaction(expires: now))
        let parts = jws.split(separator: ".").map(String.init)

        // Same header and signature, payload swapped for another user's token.
        let forged = try JSONSerialization.data(
            withJSONObject: AppStoreTestPayloads.transaction(
                expires: now.addingTimeInterval(365 * 86_400), appAccountToken: UUID()))
        try await expectVerificationError(
            .badSignature, "\(parts[0]).\(forged.base64URLEncodedString()).\(parts[2])", pki)

        // A signature from another key.
        let otherSignature = try P256.Signing.PrivateKey()
            .signature(for: Data("\(parts[0]).\(parts[1])".utf8))
        try await expectVerificationError(
            .badSignature,
            "\(parts[0]).\(parts[1]).\(otherSignature.rawRepresentation.base64URLEncodedString())",
            pki)

        // A signature that is not 64 bytes.
        try await expectVerificationError(
            .badSignature, "\(parts[0]).\(parts[1]).\(Data([1, 2, 3]).base64URLEncodedString())",
            pki)
    }

    func testMalformedInputIsRefused() async throws {
        let pki = try AppStoreTestPKI()
        for text in ["", "abc", "a.b", "a.b.c.d", "!!.!!.!!"] {
            try await expectVerificationError(.malformed("not a compact JWS"), text, pki)
        }
        let header = Data(#"{"alg":"ES256"}"#.utf8).base64URLEncodedString()
        let notJSON = Data("hello".utf8).base64URLEncodedString()
        try await expectVerificationError(
            .malformed("header or payload is not JSON"), "\(header).\(notJSON).AA", pki)
        try await expectVerificationError(
            .unsupportedHeader("x5c must hold three certificates"),
            "\(header).\(Data("{}".utf8).base64URLEncodedString()).AA", pki)
    }

    func testPayloadMissingRequiredFieldsIsMalformed() async throws {
        let pki = try AppStoreTestPKI()
        var payload = AppStoreTestPayloads.transaction(expires: now)
        payload["productId"] = nil
        do {
            _ = try await pki.verifier.verifyTransaction(try pki.sign(payload))
            XCTFail("expected malformed")
        } catch let error as AppStoreVerificationError {
            guard case .malformed = error else { return XCTFail("got \(error)") }
        }
    }

    func testNonUUIDAppAccountTokenIsIgnored() async throws {
        let pki = try AppStoreTestPKI()
        var payload = AppStoreTestPayloads.transaction(expires: now)
        payload["appAccountToken"] = "not-a-uuid"
        let transaction = try await pki.verifier.verifyTransaction(try pki.sign(payload))
        XCTAssertNil(transaction.appAccountToken)
    }

    func testNotificationAndNestedDataVerify() async throws {
        let pki = try AppStoreTestPKI()
        let uuid = UUID()
        let graceEnds = now.addingTimeInterval(16 * 86_400)
        let transaction = try pki.sign(AppStoreTestPayloads.transaction(expires: now))
        let renewal = try pki.sign(AppStoreTestPayloads.renewal(graceEnds: graceEnds))
        let signed = try pki.sign(
            AppStoreTestPayloads.notification(
                type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD", uuid: uuid,
                signedTransaction: transaction, signedRenewal: renewal))

        let payload = try await pki.verifier.verifyNotification(signed)
        XCTAssertEqual(payload.notificationType, "DID_FAIL_TO_RENEW")
        XCTAssertEqual(payload.subtype, "GRACE_PERIOD")
        XCTAssertEqual(payload.notificationUUID, uuid)
        XCTAssertEqual(payload.data?.bundleID, BundleIDs.release)
        XCTAssertEqual(payload.data?.signedTransactionInfo, transaction)

        let info = try await pki.verifier.verifyRenewalInfo(
            try unwrap(payload.data?.signedRenewalInfo))
        XCTAssertEqual(
            try XCTUnwrap(info.gracePeriodExpiresDate).timeIntervalSince1970,
            graceEnds.timeIntervalSince1970, accuracy: 0.002)
    }

    func testNotificationForAnotherAppIsRefused() async throws {
        let pki = try AppStoreTestPKI()
        let signed = try pki.sign(
            AppStoreTestPayloads.notification(type: "TEST", bundleID: "com.example.other"))
        do {
            _ = try await pki.verifier.verifyNotification(signed)
            XCTFail("expected wrongBundle")
        } catch let error as AppStoreVerificationError {
            XCTAssertEqual(error, .wrongBundle("com.example.other"))
        }
    }

    func testNotificationWithoutAppIdentityIsRefused() async throws {
        let pki = try AppStoreTestPKI()
        var payload = AppStoreTestPayloads.notification(type: "TEST")
        payload["data"] = nil
        do {
            _ = try await pki.verifier.verifyNotification(try pki.sign(payload))
            XCTFail("expected wrongBundle")
        } catch let error as AppStoreVerificationError {
            XCTAssertEqual(error, .wrongBundle(nil))
        }
    }

    func testSummaryNotificationUsesSummaryIdentity() async throws {
        let pki = try AppStoreTestPKI()
        var payload = AppStoreTestPayloads.notification(type: "RENEWAL_EXTENSION")
        payload["data"] = nil
        payload["summary"] = ["bundleId": BundleIDs.debug, "environment": "Production"]
        let decoded = try await pki.verifier.verifyNotification(try pki.sign(payload))
        XCTAssertEqual(decoded.appBundleID, BundleIDs.debug)
        XCTAssertNil(decoded.data)
    }

    // MARK: - Helpers

    private func expectVerificationError(
        _ expected: AppStoreVerificationError, _ jws: String, _ pki: AppStoreTestPKI,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        do {
            _ = try await pki.verifier.verifyTransaction(jws)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AppStoreVerificationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    private func expectUntrusted(
        _ jws: String, _ verifier: AppStoreSignedDataVerifier, file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await verifier.verifyTransaction(jws)
            XCTFail("expected an untrusted chain", file: file, line: line)
        } catch let error as AppStoreVerificationError {
            guard case .untrustedChain = error else {
                return XCTFail("expected untrustedChain, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
