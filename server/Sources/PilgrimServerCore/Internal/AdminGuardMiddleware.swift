import Crypto
import Foundation
import PilgrimAPI
import Vapor

/// The guard in front of every `/internal/admin/v1/*` route (design.md 14절, spec "신고와 운영자
/// 처리"). In order:
///
/// 1. `ADMIN_API_TOKEN` unset → 404 `NOT_FOUND`: the operator routes do not exist.
/// 2. A Cloudflare header (`Cf-Ray`, `Cf-Connecting-IP`) → 403 `FORBIDDEN`, even with the right
///    token: the request came through the tunnel, which must never reach these routes.
/// 3. `X-Admin-Token` missing or different (constant-time compare) → 401 `UNAUTHENTICATED`.
///
/// The token is read per request from `req.pilgrimConfig`, so it is never cached elsewhere.
public struct AdminGuardMiddleware: AsyncMiddleware {
    /// Headers Cloudflare adds to every request it proxies.
    public static let tunnelHeaders = ["Cf-Ray", "Cf-Connecting-IP"]

    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        guard let expected = request.pilgrimConfig.adminAPIToken, !expected.isEmpty else {
            throw APIError.notFound()
        }
        if Self.tunnelHeaders.contains(where: { request.headers.contains(name: $0) }) {
            throw APIError.forbidden("operator routes are not served through the tunnel")
        }
        guard let provided = request.headers.first(name: PilgrimHeader.adminToken),
            Self.tokensMatch(provided, expected)
        else { throw APIError.unauthenticated("admin token required") }
        return try await next.respond(to: request)
    }

    /// Compares SHA-256 digests byte by byte without an early exit, so neither the content nor
    /// the length of the expected token leaks through timing.
    static func tokensMatch(_ provided: String, _ expected: String) -> Bool {
        let lhs = SHA256.hash(data: Data(provided.utf8))
        let rhs = SHA256.hash(data: Data(expected.utf8))
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            difference |= a ^ b
        }
        return difference == 0
    }
}

extension Request {
    /// `X-Admin-Actor`, the console user's name, required on every operator action
    /// (`moderation_log.actor`). 400 when missing, blank or longer than 100 characters.
    func adminActor() throws -> String {
        let actor =
            headers.first(name: PilgrimHeader.adminActor)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !actor.isEmpty, actor.count <= 100 else {
            throw APIError.invalidRequest("\(PilgrimHeader.adminActor) header required")
        }
        return actor
    }
}
