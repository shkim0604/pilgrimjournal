import Crypto
import Foundation
import PilgrimAPI
import Vapor

/// What `POST /auth/token` returned for an authorization code.
public struct AppleTokenExchange: Sendable, Equatable {
    public var refreshToken: String
    /// `sub` of the returned `id_token`, when Apple sent one.
    public var subject: String?

    public init(refreshToken: String, subject: String?) {
        self.refreshToken = refreshToken
        self.subject = subject
    }
}

/// Apple's Sign in with Apple REST endpoints (`/auth/token`, `/auth/revoke`).
///
/// `exchange` throws `APIError` 502 `APPLE_CODE_EXCHANGE_FAILED` on any failure: sign-in must
/// fail without an Apple refresh token, or account deletion could not revoke it (design.md 3절).
public protocol AppleAuthorizationClient: Sendable {
    func exchange(authorizationCode: String, clientID: String) async throws -> AppleTokenExchange
    /// Revokes an Apple refresh token (account deletion; the S5 revocation worker).
    func revoke(refreshToken: String, clientID: String) async throws
}

public struct AppleRevocationError: Error, Equatable, CustomStringConvertible {
    public var status: Int
    public var description: String { "Apple /auth/revoke answered HTTP \(status)" }
}

/// Talks to `https://appleid.apple.com`.
public struct LiveAppleAuthorizationClient: AppleAuthorizationClient {
    public static let tokenURL: URI = "https://appleid.apple.com/auth/token"
    public static let revokeURL: URI = "https://appleid.apple.com/auth/revoke"

    let client: any Client
    let secretSigner: AppleClientSecretSigner
    let logger: Logger

    public init(client: any Client, secretSigner: AppleClientSecretSigner, logger: Logger) {
        self.client = client
        self.secretSigner = secretSigner
        self.logger = logger
    }

    private struct TokenForm: Content {
        var clientID: String
        var clientSecret: String
        var code: String
        var grantType = "authorization_code"

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case code
            case grantType = "grant_type"
        }
    }

    private struct RevokeForm: Content {
        var clientID: String
        var clientSecret: String
        var token: String
        var tokenTypeHint = "refresh_token"

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case token
            case tokenTypeHint = "token_type_hint"
        }
    }

    private struct TokenResponse: Decodable {
        var refreshToken: String?
        var idToken: String?

        enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct IDTokenPayload: Decodable {
        var sub: String?
    }

    public func exchange(authorizationCode: String, clientID: String) async throws
        -> AppleTokenExchange
    {
        let form = TokenForm(
            clientID: clientID,
            clientSecret: try secretSigner.clientSecret(clientID: clientID),
            code: authorizationCode)
        let response: ClientResponse
        do {
            response = try await client.post(Self.tokenURL) { request in
                try request.content.encode(form, as: .urlEncodedForm)
            }
        } catch {
            logger.warning("apple code exchange: request failed: \(String(describing: error))")
            throw Self.failed("Apple token endpoint unreachable")
        }
        guard (200..<300).contains(response.status.code) else {
            logger.warning("apple code exchange: HTTP \(response.status.code)")
            throw Self.failed("Apple token endpoint answered \(response.status.code)")
        }
        guard let body = response.body,
            let decoded = try? JSONDecoder().decode(TokenResponse.self, from: Data(buffer: body)),
            let refreshToken = decoded.refreshToken, !refreshToken.isEmpty
        else { throw Self.failed("Apple token response had no refresh_token") }
        let subject = decoded.idToken
            .flatMap(JWTSegments.payload(of:))
            .flatMap { try? JSONDecoder().decode(IDTokenPayload.self, from: $0) }?.sub
        return AppleTokenExchange(refreshToken: refreshToken, subject: subject)
    }

    public func revoke(refreshToken: String, clientID: String) async throws {
        let form = RevokeForm(
            clientID: clientID,
            clientSecret: try secretSigner.clientSecret(clientID: clientID),
            token: refreshToken)
        let response = try await client.post(Self.revokeURL) { request in
            try request.content.encode(form, as: .urlEncodedForm)
        }
        guard (200..<300).contains(response.status.code) else {
            throw AppleRevocationError(status: Int(response.status.code))
        }
    }

    static func failed(_ message: String) -> APIError {
        APIError(code: .appleCodeExchangeFailed, message: message)
    }
}

/// Used outside production when the Sign in with Apple key is not set: every exchange fails
/// with 502, so only development login works.
public struct UnconfiguredAppleAuthorizationClient: AppleAuthorizationClient {
    public init() {}

    public func exchange(authorizationCode: String, clientID: String) async throws
        -> AppleTokenExchange
    {
        throw APIError(
            code: .appleCodeExchangeFailed, message: "Sign in with Apple is not configured")
    }

    public func revoke(refreshToken: String, clientID: String) async throws {
        throw APIError(
            code: .appleCodeExchangeFailed, message: "Sign in with Apple is not configured")
    }
}

/// The `client_secret` for Apple's REST endpoints: an ES256 JWT signed with the Sign in with
/// Apple key (`.p8`), valid for 5 minutes. Header `kid` = key ID; claims `iss` = team ID,
/// `aud` = `https://appleid.apple.com`, `sub` = the bundle ID (client ID).
public struct AppleClientSecretSigner: Sendable {
    public static let audience = "https://appleid.apple.com"
    public static let lifetime: TimeInterval = 300

    let teamID: String
    let keyID: String
    let privateKey: P256.Signing.PrivateKey

    /// `privateKeyPEM` is the `.p8` file (PKCS#8 PEM). Escaped `\n` (one line in `.env`) is
    /// accepted.
    public init(teamID: String, keyID: String, privateKeyPEM: String) throws {
        let pem = privateKeyPEM.replacingOccurrences(of: "\\n", with: "\n")
        do {
            self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw ConfigurationError("APPLE_SIWA_PRIVATE_KEY is not a P-256 private key PEM")
        }
        self.teamID = teamID
        self.keyID = keyID
    }

    private struct Header: Encodable {
        var alg = "ES256"
        var kid: String
    }

    private struct Claims: Encodable {
        var iss: String
        var iat: Int
        var exp: Int
        var aud: String
        var sub: String
    }

    public func clientSecret(clientID: String, now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970.rounded(.down))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: keyID)).base64URLEncodedString()
        let claims = try encoder.encode(
            Claims(
                iss: teamID, iat: issuedAt, exp: issuedAt + Int(Self.lifetime),
                aud: Self.audience, sub: clientID)
        ).base64URLEncodedString()
        let signingInput = "\(header).\(claims)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }
}
