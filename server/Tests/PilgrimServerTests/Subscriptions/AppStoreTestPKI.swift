import Crypto
import Foundation
import PilgrimAPI
import SwiftASN1
import X509

@testable import PilgrimServerCore

/// A throwaway PKI shaped like the App Store's: root → intermediate (Apple WWDR OID) → leaf
/// (receipt-signing OID), plus an ES256 JWS signer with the `x5c` header. Tests hand
/// `rootDER` to `AppStoreSignedDataVerifier` in place of Apple Root CA - G3.
struct AppStoreTestPKI {
    struct Options {
        var intermediateHasWWDROID = true
        var leafHasReceiptOID = true
        var intermediateIsCA = true
        var leafNotBefore = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        var leafNotAfter = Date(timeIntervalSince1970: 2_000_000_000) // 2033-05-18
    }

    let root: Certificate
    let intermediate: Certificate
    let leaf: Certificate
    private let leafKeyBytes: Data

    init(_ options: Options = Options()) throws {
        let rootKey = P256.Signing.PrivateKey()
        let intermediateKey = P256.Signing.PrivateKey()
        let leafKey = P256.Signing.PrivateKey()
        let start = Date(timeIntervalSince1970: 1_600_000_000) // 2020-09-13
        let end = Date(timeIntervalSince1970: 2_100_000_000) // 2036-07-18

        root = try Self.certificate(
            subject: "Pilgrim Test Root CA", issuer: "Pilgrim Test Root CA",
            publicKey: rootKey.publicKey, issuerKey: rootKey, isCA: true, oid: nil,
            notBefore: start, notAfter: end)
        intermediate = try Self.certificate(
            subject: "Pilgrim Test WWDR", issuer: "Pilgrim Test Root CA",
            publicKey: intermediateKey.publicKey, issuerKey: rootKey,
            isCA: options.intermediateIsCA,
            oid: options.intermediateHasWWDROID
                ? AppStoreSignedDataVerifier.wwdrIntermediateOID : nil,
            notBefore: start, notAfter: end)
        leaf = try Self.certificate(
            subject: "Pilgrim Test StoreKit Signer", issuer: "Pilgrim Test WWDR",
            publicKey: leafKey.publicKey, issuerKey: intermediateKey, isCA: false,
            oid: options.leafHasReceiptOID ? AppStoreSignedDataVerifier.receiptSigningOID : nil,
            notBefore: options.leafNotBefore, notAfter: options.leafNotAfter)
        leafKeyBytes = leafKey.rawRepresentation
    }

    var rootDER: Data { Self.der(root) }

    var verifier: AppStoreSignedDataVerifier {
        AppStoreSignedDataVerifier(rootCertificates: [rootDER])
    }

    static func der(_ certificate: Certificate) -> Data {
        var serializer = DER.Serializer()
        // Serializing a parsed or freshly built certificate cannot fail.
        try! serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    /// Signs `payload` (a JSON object) as App Store signed data. `chain` overrides the `x5c`
    /// certificates (default leaf, intermediate, root).
    func sign(
        _ payload: [String: Any], alg: String = "ES256", chain: [Certificate]? = nil
    ) throws -> String {
        let x5c = (chain ?? [leaf, intermediate, root]).map { Self.der($0).base64EncodedString() }
        let header = try JSONSerialization.data(withJSONObject: ["alg": alg, "x5c": x5c])
        let body = try JSONSerialization.data(withJSONObject: payload)
        let signingInput = "\(header.base64URLEncodedString()).\(body.base64URLEncodedString())"
        let key = try P256.Signing.PrivateKey(rawRepresentation: leafKeyBytes)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }

    private static func certificate(
        subject: String, issuer: String, publicKey: P256.Signing.PublicKey,
        issuerKey: P256.Signing.PrivateKey, isCA: Bool, oid: ASN1ObjectIdentifier?,
        notBefore: Date, notAfter: Date
    ) throws -> Certificate {
        let extensions = try Certificate.Extensions {
            if isCA {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                KeyUsage(keyCertSign: true, cRLSign: true)
            } else {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
            }
            if let oid {
                // Apple's marker extensions carry an ASN.1 NULL.
                Certificate.Extension(oid: oid, critical: false, value: [0x05, 0x00])
            }
        }
        return try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(publicKey), notValidBefore: notBefore,
            notValidAfter: notAfter, issuer: try DistinguishedName { CommonName(issuer) },
            subject: try DistinguishedName { CommonName(subject) },
            signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(issuerKey))
    }
}

/// App Store payload builders (dates in milliseconds since 1970, as Apple sends them).
enum AppStoreTestPayloads {
    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func transaction(
        originalTransactionID: String = "2000000000000001", transactionID: String? = nil,
        bundleID: String = BundleIDs.release,
        productID: String = SubscriptionProduct.groupsMonthly, environment: String = "Sandbox",
        expires: Date?, revoked: Date? = nil, appAccountToken: UUID? = nil,
        signed: Date = Date()
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "originalTransactionId": originalTransactionID,
            "transactionId": transactionID ?? originalTransactionID,
            "bundleId": bundleID,
            "productId": productID,
            "environment": environment,
            "type": "Auto-Renewable Subscription",
            "purchaseDate": millis(signed.addingTimeInterval(-60)),
            "signedDate": millis(signed),
            "storefront": "KOR",
        ]
        if let expires { payload["expiresDate"] = millis(expires) }
        if let revoked { payload["revocationDate"] = millis(revoked) }
        if let appAccountToken { payload["appAccountToken"] = appAccountToken.uuidString }
        return payload
    }

    static func renewal(
        originalTransactionID: String = "2000000000000001", environment: String = "Sandbox",
        graceEnds: Date? = nil, signed: Date = Date()
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "originalTransactionId": originalTransactionID,
            "environment": environment,
            "autoRenewStatus": 1,
            "signedDate": millis(signed),
        ]
        if let graceEnds { payload["gracePeriodExpiresDate"] = millis(graceEnds) }
        return payload
    }

    static func notification(
        type: String, subtype: String? = nil, uuid: UUID = UUID(),
        bundleID: String = BundleIDs.release, environment: String = "Sandbox",
        signedTransaction: String? = nil, signedRenewal: String? = nil, signed: Date = Date()
    ) -> [String: Any] {
        var data: [String: Any] = [
            "bundleId": bundleID, "environment": environment, "appAppleId": 1_234_567_890,
        ]
        if let signedTransaction { data["signedTransactionInfo"] = signedTransaction }
        if let signedRenewal { data["signedRenewalInfo"] = signedRenewal }
        var payload: [String: Any] = [
            "notificationType": type,
            "notificationUUID": uuid.uuidString.lowercased(),
            "version": "2.0",
            "signedDate": millis(signed),
            "data": data,
        ]
        if let subtype { payload["subtype"] = subtype }
        return payload
    }
}
