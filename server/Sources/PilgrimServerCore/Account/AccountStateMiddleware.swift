import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// The one account gate (design.md "가입 정보와 정지", "구독 검증과 권한"). Loads the signed-in
/// user, after `UserAuthMiddleware`, and checks in this order:
///
/// - user row gone (account deleted) → 401 `UNAUTHENTICATED`
/// - suspended (`User.isSuspended(at:)`) → 403 `ACCOUNT_SUSPENDED`, unless `allowsSuspended`
/// - no display name yet → 403 `SIGNUP_REQUIRED`, when `requiresSignup`
/// - not entitled (`SubscriptionEntitlement`, only while `SUBSCRIPTION_REQUIRED=true`) → 402
///   `SUBSCRIPTION_REQUIRED`, when `requiresSubscription`
///
/// The loaded user is kept for the handler (`req.currentUser()`). Most routes use
/// `PilgrimRoutes.signedUp`; group routes use `PilgrimRoutes.groupMember`.
public struct AccountStateMiddleware: AsyncMiddleware {
    public var requiresSignup: Bool
    public var allowsSuspended: Bool
    public var requiresSubscription: Bool

    public init(
        requiresSignup: Bool = true, allowsSuspended: Bool = false,
        requiresSubscription: Bool = false
    ) {
        self.requiresSignup = requiresSignup
        self.allowsSuspended = allowsSuspended
        self.requiresSubscription = requiresSubscription
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let user = try await request.currentUser()
        let now = Date()
        try Self.check(
            user, requiresSignup: requiresSignup, allowsSuspended: allowsSuspended, now: now)
        if requiresSubscription {
            try await SubscriptionEntitlement.ensureEntitled(
                try user.requireID(),
                subscriptionRequired: request.pilgrimConfig.subscriptionRequired, on: request.db,
                now: now)
        }
        return try await next.respond(to: request)
    }

    /// The account-state part of the gate (no database): `user` is nil when the row is gone.
    static func check(
        _ user: User?, requiresSignup: Bool = true, allowsSuspended: Bool = false, now: Date
    ) throws {
        guard let user else { throw APIError.unauthenticated("account no longer exists") }
        if !allowsSuspended { try user.ensureNotSuspended(at: now) }
        if requiresSignup { try user.ensureSignedUp() }
    }
}

extension PilgrimRoutes {
    /// `authenticated` plus `AccountStateMiddleware()`: the user exists, finished sign-up and is
    /// not suspended. The route group for everything except auth and `/me` itself.
    public var signedUp: any RoutesBuilder {
        authenticated.grouped(AccountStateMiddleware())
    }

    /// `signedUp` plus the subscription while `SUBSCRIPTION_REQUIRED` is on: `groups/**`,
    /// posts, comments, reactions, stickers, votes and invite accept.
    public var groupMember: any RoutesBuilder {
        authenticated.grouped(AccountStateMiddleware(requiresSubscription: true))
    }
}

extension User {
    /// Throws 403 `ACCOUNT_SUSPENDED` while `isSuspended(at:)`.
    public func ensureNotSuspended(at now: Date = Date()) throws {
        guard isSuspended(at: now) else { return }
        throw APIError(code: .accountSuspended, message: "account is suspended")
    }

    /// Throws 403 `SIGNUP_REQUIRED` until the user has a display name.
    public func ensureSignedUp() throws {
        guard !profileComplete else { return }
        throw APIError(code: .signupRequired, message: "finish sign-up first")
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
