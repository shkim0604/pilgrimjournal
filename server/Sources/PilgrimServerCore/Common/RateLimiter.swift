import Foundation
import PilgrimAPI
import Vapor

/// In-memory token buckets (design.md 2절 "rate limit"; one API process, so memory is enough).
///
/// Each `(bucket, key)` pair starts full with `rule.requests` tokens and refills continuously at
/// `requests / window` per second. Use `RateLimitMiddleware` on a route group, or call
/// `consume` directly from a handler for a per-action budget:
///
/// ```swift
/// try await req.application.rateLimiter.consume(
///     bucket: "posts", key: try req.userID.uuidString, rule: req.pilgrimConfig.rateLimits.posts)
/// ```
public actor RateLimiter {
    private struct Bucket {
        var tokens: Double
        var updatedAt: Date
    }

    private var buckets: [String: Bucket] = [:]
    private var lastSweep = Date.distantPast

    public init() {}

    /// Takes one token, or throws 429 `RATE_LIMITED` with the seconds until one is available.
    public func consume(bucket: String, key: String, rule: RateLimitRule, now: Date = Date())
        throws
    {
        let id = "\(bucket)|\(key)"
        let capacity = Double(rule.requests)
        let refillPerSecond = capacity / rule.window
        var state = buckets[id] ?? Bucket(tokens: capacity, updatedAt: now)
        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        state.tokens = min(capacity, state.tokens + elapsed * refillPerSecond)
        state.updatedAt = now
        guard state.tokens >= 1 else {
            buckets[id] = state
            let wait = (1 - state.tokens) / refillPerSecond
            throw APIError.rateLimited(retryAfter: Int(wait.rounded(.up)))
        }
        state.tokens -= 1
        buckets[id] = state
        sweepIfNeeded(now: now, maxWindow: rule.window)
    }

    /// Drops buckets that have refilled completely, so memory stays bounded by active users.
    private func sweepIfNeeded(now: Date, maxWindow: TimeInterval) {
        guard now.timeIntervalSince(lastSweep) > 600 else { return }
        lastSweep = now
        let horizon = max(maxWindow, 86_400)
        buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) < horizon }
    }

    /// Forgets every bucket (tests).
    public func reset() {
        buckets.removeAll()
    }
}

/// Applies one rule to every request through a route group, keyed by the signed-in user, or by
/// client IP before sign-in.
public struct RateLimitMiddleware: AsyncMiddleware {
    public enum Scope: Sendable {
        /// `req.userID`; must sit after `UserAuthMiddleware`.
        case user
        /// `Cf-Connecting-IP` (Cloudflare), else the socket address.
        case ip
    }

    let bucket: String
    let scope: Scope
    let rule: @Sendable (AppConfig) -> RateLimitRule

    public init(
        bucket: String, scope: Scope, rule: @escaping @Sendable (AppConfig) -> RateLimitRule
    ) {
        self.bucket = bucket
        self.scope = scope
        self.rule = rule
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let key: String
        switch scope {
        case .user: key = try request.userID.uuidString
        case .ip: key = request.clientIP
        }
        try await request.application.rateLimiter.consume(
            bucket: bucket, key: key, rule: rule(request.pilgrimConfig))
        return try await next.respond(to: request)
    }
}

extension Request {
    /// The caller's IP: Cloudflare's `Cf-Connecting-IP` when the request came through the tunnel,
    /// otherwise the peer address.
    public var clientIP: String {
        if let forwarded = headers.first(name: "Cf-Connecting-IP"), !forwarded.isEmpty {
            return forwarded
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}
