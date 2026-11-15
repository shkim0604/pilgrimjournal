import Foundation
import JWT
import PilgrimAPI

@testable import PilgrimServerCore

/// A JWKS endpoint the tests control. Counts fetches.
actor FakeJWKSSource: AppleJWKSSource {
    private(set) var fetchCount = 0
    private var kids: [String]

    init(kids: [String] = [AppleTestKeys.firstKID]) {
        self.kids = kids
    }

    func publish(kids: [String]) {
        self.kids = kids
    }

    func fetchJWKS() async throws -> Data {
        fetchCount += 1
        return AppleTestTokens.jwks(kids: kids)
    }
}

/// Stands in for Apple's `/auth/token`.
struct FakeAppleAuthorization: AppleAuthorizationClient {
    enum Outcome: Sendable {
        case succeed(refreshToken: String, subject: String?)
        case httpFailure
    }

    var outcome: Outcome

    func exchange(authorizationCode: String, clientID: String) async throws -> AppleTokenExchange {
        switch outcome {
        case .succeed(let refreshToken, let subject):
            return AppleTokenExchange(refreshToken: refreshToken, subject: subject)
        case .httpFailure:
            throw APIError(code: .appleCodeExchangeFailed, message: "fake 400")
        }
    }

    func revoke(refreshToken: String, clientID: String) async throws {}
}

/// Builds Apple-like identity tokens signed with `AppleTestKeys`.
enum AppleTestTokens {
    static let rawNonce = "raw-nonce-0123456789abcdef"

    struct Claims: JWTPayload {
        var iss: String
        var aud: String
        var sub: String
        var iat: Int
        var exp: Int
        var nonce: String?

        func verify(using signer: JWTSigner) throws {}
    }

    static func jwks(kids: [String]) -> Data {
        let keys = kids.map { kid -> [String: String] in
            let modulus =
                kid == AppleTestKeys.secondKID
                ? AppleTestKeys.secondModulus : AppleTestKeys.firstModulus
            return [
                "kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": modulus,
                "e": AppleTestKeys.exponent,
            ]
        }
        return try! JSONSerialization.data(withJSONObject: ["keys": keys])
    }

    static func token(
        sub: String = "001234.apple-test-user", aud: String = BundleIDs.release,
        iss: String = AppleIdentityTokenVerifier.issuer, kid: String = AppleTestKeys.firstKID,
        signingKeyPEM: String? = nil,
        nonce: String? = AppleIdentityTokenVerifier.nonceHash(rawNonce),
        expiresIn: TimeInterval = 600, now: Date = Date()
    ) throws -> String {
        let pem =
            signingKeyPEM
            ?? (kid == AppleTestKeys.secondKID
                ? AppleTestKeys.secondPrivateKeyPEM : AppleTestKeys.firstPrivateKeyPEM)
        let issuedAt = Int(now.timeIntervalSince1970)
        let claims = Claims(
            iss: iss, aud: aud, sub: sub, iat: issuedAt, exp: issuedAt + Int(expiresIn),
            nonce: nonce)
        let signer = JWTSigner.rs256(key: try RSAKey.private(pem: pem))
        return try signer.sign(claims, kid: JWKIdentifier(string: kid))
    }
}
