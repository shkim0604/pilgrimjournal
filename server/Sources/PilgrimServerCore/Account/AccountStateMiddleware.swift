import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Loads the signed-in user and checks their account state, after `UserAuthMiddleware`:
///
/// - user row gone (account deleted) → 401 `UNAUTHENTICATED`
/// - suspended (`User.isSuspended(at:)`) → 403 `ACCOUNT_SUSPENDED`, unless `allowsSuspended`
/// - no display name yet → 403 `SIGNUP_REQUIRED`, when `requiresSignup`
///
/// The loaded user is kept for the handler (`req.currentUser()`). Most routes use
/// `PilgrimRoutes.signedUp`, which applies both checks.
public struct AccountStateMiddleware: AsyncMiddleware {
    public var requiresSignup: Bool
    public var allowsSuspended: Bool

    public init(requiresSignup: Bool = true, allowsSuspended: Bool = false) {
        self.requiresSignup = requiresSignup
        self.allowsSuspended = allowsSuspended
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let user = try await request.currentUser()
        if !allowsSuspended { try user.ensureNotSuspended() }
        if requiresSignup, !user.profileComplete {
            throw APIError(code: .signupRequired, message: "finish sign-up first")
        }
        return try await next.respond(to: request)
    }
}

extension PilgrimRoutes {
    /// `authenticated` plus `AccountStateMiddleware()`: the user exists, finished sign-up and is
    /// not suspended. The route group for everything except auth and `/me` itself.
    public var signedUp: any RoutesBuilder {
        authenticated.grouped(AccountStateMiddleware())
    }
}

extension User {
    /// Throws 403 `ACCOUNT_SUSPENDED` while `isSuspended(at:)`.
    public func ensureNotSuspended(at now: Date = Date()) throws {
        guard isSuspended(at: now) else { return }
        throw APIError(code: .accountSuspended, message: "account is suspended")
    }
}

extension Request {
    private struct CurrentUserKey: StorageKey {
        typealias Value = User
    }

    /// The signed-in user's row, loaded once per request. Throws 401 when there is no signed-in
    /// user or the account no longer exists.
    public func currentUser() async throws -> User {
        if let user = storage[CurrentUserKey.self] { return user }
        guard let user = try await User.find(try userID, on: db) else {
            throw APIError.unauthenticated("account no longer exists")
        }
        storage[CurrentUserKey.self] = user
        return user
    }

    /// Replaces the cached user after a handler changed it.
    func cacheCurrentUser(_ user: User) {
        storage[CurrentUserKey.self] = user
    }
}
