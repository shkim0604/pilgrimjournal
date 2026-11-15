import Crypto
import Foundation
import PilgrimAPI
import Vapor

/// The App Store Server API's `getAllSubscriptionStatuses`, for the worker's re-check of
/// subscriptions whose webhook may have been missed (design.md 12절). Tests use a fake.
public protocol AppStoreStatusFetching: Sendable {
    func subscriptionStatuses(
        originalTransactionID: String, bundleID: String,
        environment: AppStoreSubscription.Environment
    ) async throws -> AppStoreStatusResponse
}

public struct AppStoreStatusError: Error, Equatable, CustomStringConvertible {
    public var status: Int
    public var description: String { "App Store Server API answered HTTP \(status)" }
}

/// Calls `api.storekit(-sandbox).itunes.apple.com` with an ES256 token signed by the In-App
/// Purchase key (`APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`).
public struct LiveAppStoreStatusClient: AppStoreStatusFetching {
    public static let productionBaseURL = "https://api.storekit.itunes.apple.com"
    public static let sandboxBaseURL = "https://api.storekit-sandbox.itunes.apple.com"

    let client: any Client
    let signer: AppStoreAPITokenSigner

    public init(client: any Client, signer: AppStoreAPITokenSigner) {
        self.client = client
        self.signer = signer
    }

    public func subscriptionStatuses(
        originalTransactionID: String, bundleID: String,
        environment: AppStoreSubscription.Environment
    ) async throws -> AppStoreStatusResponse {
        let base = environment == .production ? Self.productionBaseURL : Self.sandboxBaseURL
        guard
            let escaped = originalTransactionID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed)
        else { throw AppStoreStatusError(status: 0) }
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(
            token: try signer.token(bundleID: bundleID))
        let response = try await client.get(
            URI(string: "\(base)/inApps/v1/subscriptions/\(escaped)"), headers: headers)
        guard response.status == .ok, let body = response.body else {
            throw AppStoreStatusError(status: Int(response.status.code))
        }
        return try JSONDecoder().decode(AppStoreStatusResponse.self, from: Data(buffer: body))
    }
}

/// Signs App Store Server API tokens (ES256, `aud = appstoreconnect-v1`, 5 minutes).
public struct AppStoreAPITokenSigner: Sendable {
    public static let audience = "appstoreconnect-v1"
    public static let lifetime: TimeInterval = 300

    let issuerID: String
    let keyID: String
    /// The raw P-256 scalar (swift-crypto keys are not `Sendable` on Linux).
    private let privateKeyBytes: Data

    /// `privateKeyPEM` is the In-App Purchase `.p8` (PKCS#8 PEM); escaped `\n` is accepted.
    public init(issuerID: String, keyID: String, privateKeyPEM: String) throws {
        let pem = privateKeyPEM.replacingOccurrences(of: "\\n", with: "\n")
        do {
            self.privateKeyBytes = try P256.Signing.PrivateKey(pemRepresentation: pem)
                .rawRepresentation
        } catch {
            throw ConfigurationError("APPSTORE_PRIVATE_KEY is not a P-256 private key PEM")
        }
        self.issuerID = issuerID
        self.keyID = keyID
    }

    private struct Header: Encodable {
        var alg = "ES256"
        var kid: String
        var typ = "JWT"
    }

    private struct Claims: Encodable {
        var iss: String
        var iat: Int
        var exp: Int
        var aud: String
        var bid: String
    }

    public func token(bundleID: String, now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970.rounded(.down))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: keyID)).base64URLEncodedString()
        let claims = try encoder.encode(
            Claims(
                iss: issuerID, iat: issuedAt, exp: issuedAt + Int(Self.lifetime),
                aud: Self.audience, bid: bundleID)
        ).base64URLEncodedString()
        let signingInput = "\(header).\(claims)"
        let key = try P256.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }
}

/// What the Subscriptions module uses, built by `SubscriptionsModule.register`. Tests replace it
/// after `configure` (a test root certificate, a fake status client).
public struct SubscriptionServices: Sendable {
    public var verifier: AppStoreSignedDataVerifier
    /// nil without the In-App Purchase key: the worker then skips the re-check.
    public var statusClient: (any AppStoreStatusFetching)?

    public init(verifier: AppStoreSignedDataVerifier, statusClient: (any AppStoreStatusFetching)?) {
        self.verifier = verifier
        self.statusClient = statusClient
    }

    public static func make(config: AppConfig, client: any Client, logger: Logger) throws
        -> SubscriptionServices
    {
        var statusClient: (any AppStoreStatusFetching)?
        if let issuerID = config.appStoreIssuerID, let keyID = config.appStoreKeyID,
            let privateKey = config.appStorePrivateKey
        {
            statusClient = LiveAppStoreStatusClient(
                client: client,
                signer: try AppStoreAPITokenSigner(
                    issuerID: issuerID, keyID: keyID, privateKeyPEM: privateKey))
        } else if config.subscriptionRequired {
            logger.warning(
                "SUBSCRIPTION_REQUIRED is on without APPSTORE_ISSUER_ID/KEY_ID/PRIVATE_KEY; missed App Store notifications will not be re-checked"
            )
        }
        return SubscriptionServices(
            verifier: AppStoreSignedDataVerifier(bundleIDs: config.allowedBundleIDs),
            statusClient: statusClient)
    }
}

extension Application {
    private struct SubscriptionServicesKey: StorageKey {
        typealias Value = SubscriptionServices
    }

    /// Set by `SubscriptionsModule.register`.
    public var subscriptionServices: SubscriptionServices {
        get {
            guard let services = storage[SubscriptionServicesKey.self] else {
                fatalError("SubscriptionsModule.register has not run")
            }
            return services
        }
        set { storage[SubscriptionServicesKey.self] = newValue }
    }
}
