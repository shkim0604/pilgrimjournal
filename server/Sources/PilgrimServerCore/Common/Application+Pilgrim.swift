import Vapor

/// Shared services every module reads from `app` / `req`, set up once by `configure`.
extension Application {
    private struct ConfigKey: StorageKey {
        typealias Value = AppConfig
    }

    /// The settings `configure(_:config:)` was called with.
    public var pilgrimConfig: AppConfig {
        get {
            guard let config = storage[ConfigKey.self] else {
                fatalError("configure(_:config:) has not run")
            }
            return config
        }
        set { storage[ConfigKey.self] = newValue }
    }

    private struct RoutesKey: StorageKey {
        typealias Value = PilgrimRoutes
    }

    /// The route groups modules attach to (see `PilgrimRoutes`).
    public var pilgrimRoutes: PilgrimRoutes {
        get {
            guard let routes = storage[RoutesKey.self] else {
                fatalError("configure(_:config:) has not run")
            }
            return routes
        }
        set { storage[RoutesKey.self] = newValue }
    }

    private struct MediaStoreKey: StorageKey {
        typealias Value = any MediaStore
    }

    /// Where photo files live. Tests may replace it after `configure`.
    public var mediaStore: any MediaStore {
        get {
            guard let store = storage[MediaStoreKey.self] else {
                fatalError("configure(_:config:) has not run")
            }
            return store
        }
        set { storage[MediaStoreKey.self] = newValue }
    }

    private struct TokenVerifierKey: StorageKey {
        typealias Value = any AccessTokenVerifying
    }

    /// Turns a bearer token into a user. S1 installs the JWT verifier; until then every token is
    /// refused. Tests may replace it after `configure`.
    public var accessTokenVerifier: any AccessTokenVerifying {
        get { storage[TokenVerifierKey.self] ?? RejectingAccessTokenVerifier() }
        set { storage[TokenVerifierKey.self] = newValue }
    }

    private struct RateLimiterKey: StorageKey {
        typealias Value = RateLimiter
    }

    /// The process-wide in-memory rate limiter (one API instance, design.md Non-Goals).
    public var rateLimiter: RateLimiter {
        if let limiter = storage[RateLimiterKey.self] { return limiter }
        let limiter = RateLimiter()
        storage[RateLimiterKey.self] = limiter
        return limiter
    }

    private struct WorkerJobsKey: StorageKey {
        typealias Value = WorkerJobRegistry
    }

    /// Loops the `worker` command runs. Modules add theirs in their `register(_:)`.
    public var workerJobs: WorkerJobRegistry {
        if let registry = storage[WorkerJobsKey.self] { return registry }
        let registry = WorkerJobRegistry()
        storage[WorkerJobsKey.self] = registry
        return registry
    }
}

extension Request {
    public var pilgrimConfig: AppConfig { application.pilgrimConfig }
    public var mediaStore: any MediaStore { application.mediaStore }
}

/// The route groups `configure` builds before calling the module registrars.
///
/// - `root`: no checks (AASA, `/i/:code`, signed media files, App Store webhook).
/// - `v1`: `/api/v1` with the `X-Pilgrim-Client` gate and the per-IP limit — for the
///   sign-in endpoints that run before there is a user.
/// - `authenticated`: `v1` plus a valid access token (`req.userID`) and the per-user limit.
/// - `admin`: `/internal/admin/v1` with no client gate. The operator guard (`X-Admin-Token`,
///   `Cf-Ray` refusal) is added by the Internal/Moderation module (S4).
public struct PilgrimRoutes: @unchecked Sendable {
    public var root: any RoutesBuilder
    public var v1: any RoutesBuilder
    public var authenticated: any RoutesBuilder
    public var admin: any RoutesBuilder
}
