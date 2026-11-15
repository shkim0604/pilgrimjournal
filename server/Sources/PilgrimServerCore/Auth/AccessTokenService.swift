import Foundation
import JWT
import PilgrimAPI
import Vapor

/// Issues and checks access tokens (design.md 3절 "세션 토큰"): HS256 JWTs signed with
/// `JWT_SECRET`, 15 minutes, claims `sub` (user), `sid` (refresh family), `iat`, `exp`,
/// `iss = "pilgrim"`, `aud = "pilgrim-app"`.
///
/// `AuthModule` installs it as `app.accessTokenVerifier`. Expired → 401 `TOKEN_EXPIRED`; any other
/// problem → 401 `UNAUTHENTICATED`.
public struct AccessTokenService: AccessTokenVerifying {
    public static let issuer = "pilgrim"
    public static let audience = "pilgrim-app"

    let secret: Data
    public let lifetime: TimeInterval

    public init(secret: String, lifetime: TimeInterval = SessionLifetime.accessToken) {
        self.secret = Data(secret.utf8)
        self.lifetime = lifetime
    }

    private var signer: JWTSigner { .hs256(key: secret) }

    public func issue(userID: UUID, sessionID: UUID, now: Date = Date()) throws -> (
        token: String, expiresAt: Date
    ) {
        let issuedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let expiresAt = issuedAt.addingTimeInterval(lifetime.rounded(.down))
        let claims = AccessTokenClaims(
            sub: SubjectClaim(value: userID.pilgrimString), sid: sessionID.pilgrimString,
            iat: IssuedAtClaim(value: issuedAt), exp: ExpirationClaim(value: expiresAt),
            iss: IssuerClaim(value: Self.issuer), aud: AudienceClaim(value: [Self.audience]))
        return (try signer.sign(claims), expiresAt)
    }

    public func verify(_ token: String, for request: Request) async throws -> AuthenticatedUser {
        try verify(token, now: Date())
    }

    /// Signature first, then the claims, then expiry.
    public func verify(_ token: String, now: Date) throws -> AuthenticatedUser {
        let claims: AccessTokenClaims
        do {
            claims = try signer.verify(token, as: AccessTokenClaims.self)
        } catch {
            throw APIError.unauthenticated("invalid access token")
        }
        guard claims.iss.value == Self.issuer, claims.aud.value.contains(Self.audience),
            let userID = UUID(uuidString: claims.sub.value),
            let sessionID = UUID(uuidString: claims.sid)
        else { throw APIError.unauthenticated("invalid access token") }
        guard claims.exp.value > now else {
            throw APIError(code: .tokenExpired, message: "access token expired")
        }
        return AuthenticatedUser(id: userID, sessionID: sessionID)
    }
}

struct AccessTokenClaims: JWTPayload {
    var sub: SubjectClaim
    var sid: String
    var iat: IssuedAtClaim
    var exp: ExpirationClaim
    var iss: IssuerClaim
    var aud: AudienceClaim

    /// Checked by `AccessTokenService.verify` after the signature.
    func verify(using signer: JWTSigner) throws {}
}
