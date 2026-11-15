import Crypto
import Foundation
import PilgrimAPI
import SwiftASN1
import X509

/// Why App Store signed data was refused. Every case is a 422 `SUBSCRIPTION_INVALID` for
/// `POST /subscriptions/verify` and a 400 for the notification webhook.
public enum AppStoreVerificationError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not three base64url segments, bad JSON, or a payload missing a required field.
    case malformed(String)
    /// `alg` is not ES256 or `x5c` is not a leaf, intermediate and root.
    case unsupportedHeader(String)
    /// The `x5c` chain does not lead to a trusted root with Apple's certificate OIDs, or a
    /// certificate was not valid at the payload's `signedDate`.
    case untrustedChain(String)
    /// The ES256 signature does not match the leaf certificate's key.
    case badSignature
    /// Signed for an app other than the two Pilgrim bundle IDs (or not the one requested).
    case wrongBundle(String?)
    /// Not `Production` or `Sandbox` (Xcode and local StoreKit testing are not Apple-signed).
    case wrongEnvironment(String?)

    public var description: String {
        switch self {
        case .malformed(let reason): "malformed signed data: \(reason)"
        case .unsupportedHeader(let reason): "unsupported JWS header: \(reason)"
        case .untrustedChain(let reason): "untrusted certificate chain: \(reason)"
        case .badSignature: "signature does not verify"
        case .wrongBundle(let bundle): "unexpected bundle ID \(bundle ?? "nil")"
        case .wrongEnvironment(let environment): "unexpected environment \(environment ?? "nil")"
        }
    }
}

/// Verifies App Store signed data (JWS with an `x5c` chain) the way Apple's
/// `SignedDataVerifier` does, without its online OCSP check:
///
/// 1. `alg` is ES256 and `x5c` holds exactly leaf, intermediate, root;
/// 2. leaf → intermediate chains to one of `rootCertificates` (Apple Root CA - G3 in production)
///    under RFC 5280 rules at the payload's `signedDate` (or now when there is none);
/// 3. the intermediate carries Apple's WWDR OID `1.2.840.113635.100.6.2.1` and the leaf the
///    receipt-signing OID `1.2.840.113635.100.6.11.1`;
/// 4. the ES256 signature verifies with the leaf key;
/// 5. the bundle ID is one of `bundleIDs` and the environment `Production` or `Sandbox`.
///
/// Both environments are accepted on every server: App Review buys with Sandbox accounts
/// against the production server.
///
/// Holds certificate DER bytes, not parsed `Certificate`s or keys, so it stays `Sendable` on
/// Linux.
public struct AppStoreSignedDataVerifier: Sendable {
    public static let wwdrIntermediateOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 6, 2, 1]
    public static let receiptSigningOID: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 6, 11, 1]

    let rootCertificates: [Data]
    let bundleIDs: Set<String>
    let environments: Set<String>

    /// `rootCertificates` are DER certificates; tests pass their own test root.
    public init(
        rootCertificates: [Data] = [AppleRootCertificates.appleRootCAG3],
        bundleIDs: Set<String> = BundleIDs.all
    ) {
        self.rootCertificates = rootCertificates
        self.bundleIDs = bundleIDs
        self.environments = Set(AppStoreSubscription.Environment.allCases.map(\.rawValue))
    }

    // MARK: - Payload types

    /// A StoreKit 2 signed transaction. `expectedBundleID`, when given, must also match (the
    /// `bundleId` the app sent with it).
    public func verifyTransaction(_ jws: String, expectedBundleID: String? = nil) async throws
        -> AppStoreTransaction
    {
        let transaction = try await verify(jws, as: AppStoreTransaction.self)
        try checkApp(bundleID: transaction.bundleID, environment: transaction.environment)
        if let expectedBundleID, expectedBundleID != transaction.bundleID {
            throw AppStoreVerificationError.wrongBundle(transaction.bundleID)
        }
        return transaction
    }

    public func verifyRenewalInfo(_ jws: String) async throws -> AppStoreRenewalInfo {
        let info = try await verify(jws, as: AppStoreRenewalInfo.self)
        guard let environment = info.environment, environments.contains(environment) else {
            throw AppStoreVerificationError.wrongEnvironment(info.environment)
        }
        return info
    }

    /// An App Store Server Notification V2 `signedPayload`. The nested `signedTransactionInfo` /
    /// `signedRenewalInfo` are verified separately by the caller.
    public func verifyNotification(_ signedPayload: String) async throws
        -> AppStoreNotificationPayload
    {
        let payload = try await verify(signedPayload, as: AppStoreNotificationPayload.self)
        try checkApp(bundleID: payload.appBundleID, environment: payload.appEnvironment)
        return payload
    }

    private func checkApp(bundleID: String?, environment: String?) throws {
        guard let bundleID, bundleIDs.contains(bundleID) else {
            throw AppStoreVerificationError.wrongBundle(bundleID)
        }
        guard let environment, environments.contains(environment) else {
            throw AppStoreVerificationError.wrongEnvironment(environment)
        }
    }

    // MARK: - JWS

    private struct Header: Decodable {
        var alg: String?
        var x5c: [String]?
    }

    private struct SignedDateOnly: Decodable {
        var signedDate: Date?
    }

    /// Checks the chain and signature, then decodes the payload as `T`.
    func verify<T: Decodable>(_ jws: String, as type: T.Type) async throws -> T {
        let segments = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let headerData = Data(base64URLEncoded: String(segments[0])),
            let payloadData = Data(base64URLEncoded: String(segments[1])),
            let signatureData = Data(base64URLEncoded: String(segments[2]))
        else { throw AppStoreVerificationError.malformed("not a compact JWS") }

        let header: Header
        let signedDate: Date?
        do {
            header = try JSONDecoder().decode(Header.self, from: headerData)
            signedDate = try AppStorePayloadDecoding.decode(SignedDateOnly.self, from: payloadData)
                .signedDate
        } catch {
            throw AppStoreVerificationError.malformed("header or payload is not JSON")
        }
        guard header.alg == "ES256" else {
            throw AppStoreVerificationError.unsupportedHeader("alg \(header.alg ?? "nil")")
        }
        guard let x5c = header.x5c, x5c.count == 3 else {
            throw AppStoreVerificationError.unsupportedHeader("x5c must hold three certificates")
        }

        let leaf = try Self.certificate(x5c[0])
        let intermediate = try Self.certificate(x5c[1])
        try await validateChain(
            leaf: leaf, intermediate: intermediate, at: signedDate ?? Date())

        guard let key = P256.Signing.PublicKey(leaf.publicKey) else {
            throw AppStoreVerificationError.untrustedChain("leaf key is not P-256")
        }
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        else { throw AppStoreVerificationError.badSignature }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard key.isValidSignature(signature, for: signingInput) else {
            throw AppStoreVerificationError.badSignature
        }

        do {
            return try AppStorePayloadDecoding.decode(type, from: payloadData)
        } catch {
            throw AppStoreVerificationError.malformed("payload: \(error)")
        }
    }

    private static func certificate(_ base64: String) throws -> Certificate {
        guard let der = Data(base64Encoded: base64) else {
            throw AppStoreVerificationError.malformed("x5c entry is not base64")
        }
        do {
            return try Certificate(derEncoded: Array(der))
        } catch {
            throw AppStoreVerificationError.malformed("x5c entry is not a certificate")
        }
    }

    private func validateChain(leaf: Certificate, intermediate: Certificate, at time: Date)
        async throws
    {
        let roots: [Certificate]
        do {
            roots = try rootCertificates.map { try Certificate(derEncoded: Array($0)) }
        } catch {
            throw AppStoreVerificationError.untrustedChain("a configured root is not a certificate")
        }
        var verifier = Verifier(rootCertificates: CertificateStore(roots)) {
            RFC5280Policy(validationTime: time)
            AppStoreCertificatePolicy()
        }
        let result = await verifier.validate(
            leaf: leaf, intermediates: CertificateStore([intermediate]))
        guard case .validCertificate(let chain) = result else {
            throw AppStoreVerificationError.untrustedChain("no valid chain to a trusted root")
        }
        guard chain.first == leaf else {
            throw AppStoreVerificationError.untrustedChain("chain does not start at the leaf")
        }
    }
}

/// Apple's App Store chain rule (`AppStoreOIDPolicy` in app-store-server-library): exactly leaf,
/// WWDR intermediate, root.
struct AppStoreCertificatePolicy: VerifierPolicy {
    let verifyingCriticalExtensions: [ASN1ObjectIdentifier] = []

    mutating func chainMeetsPolicyRequirements(chain: UnverifiedCertificateChain) async
        -> PolicyEvaluationResult
    {
        guard chain.count == 3 else {
            return .failsToMeetPolicy(reason: "chain has \(chain.count) certificates, not 3")
        }
        guard
            chain[1].extensions.contains(where: {
                $0.oid == AppStoreSignedDataVerifier.wwdrIntermediateOID
            })
        else {
            return .failsToMeetPolicy(reason: "intermediate lacks the Apple WWDR OID")
        }
        guard
            chain[0].extensions.contains(where: {
                $0.oid == AppStoreSignedDataVerifier.receiptSigningOID
            })
        else {
            return .failsToMeetPolicy(reason: "leaf lacks the App Store receipt-signing OID")
        }
        return .meetsPolicy
    }
}
