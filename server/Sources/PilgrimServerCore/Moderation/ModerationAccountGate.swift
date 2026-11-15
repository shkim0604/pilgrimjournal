import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Account-state checks for the moderation routes, read straight from `users` (design.md 14절
/// "정지", 오류 표 `SIGNUP_REQUIRED`):
///
/// - no `users` row for the token's user → 401 `UNAUTHENTICATED` (the account is gone),
/// - suspended (`User.isSuspended(at:)`) → 403 `ACCOUNT_SUSPENDED`,
/// - no display name yet → 403 `SIGNUP_REQUIRED`.
///
/// S1's shared account middleware does the same for every group route; Phase 2 may replace this
/// with it. Must sit after `UserAuthMiddleware` (`routes.authenticated`).
struct ModerationAccountGate: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        try Self.check(try await User.find(try request.userID, on: request.db), now: Date())
        return try await next.respond(to: request)
    }

    static func check(_ user: User?, now: Date) throws {
        guard let user else { throw APIError.unauthenticated("account not found") }
        if user.isSuspended(at: now) {
            throw APIError(code: .accountSuspended, message: "account suspended")
        }
        guard user.profileComplete else {
            throw APIError(code: .signupRequired, message: "choose a display name first")
        }
    }
}
