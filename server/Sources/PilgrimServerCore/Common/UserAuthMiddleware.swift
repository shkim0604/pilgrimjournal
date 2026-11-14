import Foundation
import PilgrimAPI
import Vapor

/// The signed-in user of a request, set by `UserAuthMiddleware`.
public struct AuthenticatedUser: Authenticatable, Sendable, Equatable {
    public var id: UUID
    /// The refresh-token family (`sid` claim) the access token was minted for.
    public var sessionID: UUID?

    public init(id: UUID, sessionID: UUID? = nil) {
        self.id = id
        self.sessionID = sessionID
    }
}

/// Verifies an access token. S1 installs the HS256 JWT verifier (design.md 3절 "세션 토큰") as
/// `app.accessTokenVerifier`; it throws `APIError` `.tokenExpired` or `.unauthenticated`.
public protocol AccessTokenVerifying: Sendable {
    func verify(_ token: String, for request: Request) async throws -> AuthenticatedUser
}

/// The default until S1 lands: no token is valid.
public struct RejectingAccessTokenVerifier: AccessTokenVerifying {
    public init() {}

    public func verify(_ token: String, for request: Request) async throws -> AuthenticatedUser {
        throw APIError.unauthenticated("access tokens are not configured")
    }
}

/// Requires `Authorization: Bearer <accessToken>` and logs the user in (`req.userID`).
///
/// Account-state checks that need the database (`SIGNUP_REQUIRED`, `ACCOUNT_SUSPENDED`,
/// subscription) are separate middleware the Account/Subscriptions modules add per route group.
public struct UserAuthMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        guard let bearer = request.headers.bearerAuthorization, !bearer.token.isEmpty else {
            throw APIError.unauthenticated()
        }
        let user = try await request.application.accessTokenVerifier.verify(
            bearer.token, for: request)
        request.auth.login(user)
        return try await next.respond(to: request)
    }
}

extension Request {
    /// The signed-in user's ID. Throws 401 outside `PilgrimRoutes.authenticated`.
    public var userID: UUID {
        get throws {
            guard let user = auth.get(AuthenticatedUser.self) else {
                throw APIError.unauthenticated()
            }
            return user.id
        }
    }

    public var authenticatedUser: AuthenticatedUser? { auth.get(AuthenticatedUser.self) }
}
