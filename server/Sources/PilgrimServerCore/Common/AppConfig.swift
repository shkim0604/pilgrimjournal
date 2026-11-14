import Foundation
import PilgrimAPI

/// Server settings read from the environment (design.md "환경 변수"). Built once at start-up;
/// `serve` and `worker` read the same variables.
///
/// Secrets that later tasks need (Apple keys, APNs key, App Store key) are read here as optional
/// strings so every module finds them in one place; the module that uses a value checks it is set
/// when it registers.
public struct AppConfig: Sendable {
    public enum Environment: String, Sendable, CaseIterable {
        case development, production, testing
    }

    public var appEnvironment: Environment
    public var databaseURL: String
    /// Public origin, for invite links and signed media URLs. No trailing slash.
    public var publicBaseURL: URL
    public var httpHost: String
    public var httpPort: Int
    /// Reported by `GET /api/health`.
    public var version: String

    public var jwtSecret: String?
    public var appleTeamID: String?
    public var appleSignInKeyID: String?
    public var appleSignInPrivateKey: String?
    public var appleTokenEncryptionKey: String?
    public var apnsKeyID: String?
    public var apnsPrivateKey: String?
    public var appStoreIssuerID: String?
    public var appStoreKeyID: String?
    public var appStorePrivateKey: String?

    /// Root of the photo volume (`MEDIA_ROOT`).
    public var mediaRoot: String
    public var mediaURLSecret: String
    /// `ADMIN_API_TOKEN`; operator routes are refused while it is nil.
    public var adminAPIToken: String?
    public var reportWebhookURL: URL?

    public var subscriptionRequired: Bool
    public var minimumClientVersion: ClientVersion?
    public var devLoginEnabled: Bool
    /// One "day" for expiry, votes, grace periods and invites (`TIME_SCALE_DAY_SECONDS`).
    /// Loop intervals do not scale with it.
    public var dayLength: TimeInterval
    /// Bundle IDs accepted in `X-Pilgrim-Client`, `aud` and as APNs topics.
    public var allowedBundleIDs: Set<String>
    public var rateLimits: RateLimits

    public var isProduction: Bool { appEnvironment == .production }

    public static let defaultDayLength: TimeInterval = 86_400
    public static let minimumAdminTokenBytes = 32
}

public struct ConfigurationError: Error, CustomStringConvertible, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

extension AppConfig {
    /// Reads the configuration from `environment` (normally `ProcessInfo.processInfo.environment`).
    /// Throws for missing required values and for settings refused in production.
    public init(environment env: [String: String]) throws {
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
            else { return nil }
            return raw
        }
        func flag(_ key: String, default defaultValue: Bool) throws -> Bool {
            guard let raw = value(key) else { return defaultValue }
            switch raw.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw ConfigurationError("\(key) must be true or false, got \(raw)")
            }
        }

        let environmentName = value("APP_ENV") ?? Environment.development.rawValue
        guard let appEnvironment = Environment(rawValue: environmentName) else {
            throw ConfigurationError(
                "APP_ENV must be development, production or testing, got \(environmentName)")
        }
        let isProduction = appEnvironment == .production

        guard let databaseURL = value("DATABASE_URL") else {
            throw ConfigurationError("DATABASE_URL is required")
        }

        let baseURLText =
            value("PUBLIC_BASE_URL")
            ?? (isProduction ? APIPaths.productionBaseURL.absoluteString : "http://localhost:3100")
        guard let publicBaseURL = URL(string: baseURLText.trimmingSuffix("/")),
            publicBaseURL.scheme == "https" || publicBaseURL.scheme == "http"
        else { throw ConfigurationError("PUBLIC_BASE_URL is not an http(s) URL: \(baseURLText)") }

        let port: Int
        if let portText = value("PORT") {
            guard let parsed = Int(portText), (1...65_535).contains(parsed) else {
                throw ConfigurationError("PORT must be 1...65535, got \(portText)")
            }
            port = parsed
        } else {
            port = 3100
        }

        let dayLength: TimeInterval
        if let text = value("TIME_SCALE_DAY_SECONDS") ?? value("DAY_LENGTH_SECONDS") {
            guard let seconds = TimeInterval(text), seconds >= 1 else {
                throw ConfigurationError("TIME_SCALE_DAY_SECONDS must be a positive number")
            }
            dayLength = seconds
        } else {
            dayLength = Self.defaultDayLength
        }

        let minimumClientVersion: ClientVersion?
        if let text = value("MIN_CLIENT_VERSION") {
            guard let version = ClientVersion(text) else {
                throw ConfigurationError("MIN_CLIENT_VERSION is not a version: \(text)")
            }
            minimumClientVersion = version
        } else {
            minimumClientVersion = nil
        }

        let reportWebhookURL: URL?
        if let text = value("REPORT_WEBHOOK_URL") {
            guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
                throw ConfigurationError("REPORT_WEBHOOK_URL is not an http(s) URL")
            }
            reportWebhookURL = url
        } else {
            reportWebhookURL = nil
        }

        let mediaURLSecret = value("MEDIA_URL_SECRET")
        let jwtSecret = value("JWT_SECRET")
        let adminAPIToken = value("ADMIN_API_TOKEN")

        self.init(
            appEnvironment: appEnvironment,
            databaseURL: databaseURL,
            publicBaseURL: publicBaseURL,
            httpHost: value("HTTP_HOST") ?? "127.0.0.1",
            httpPort: port,
            version: value("APP_VERSION") ?? "dev",
            jwtSecret: jwtSecret,
            appleTeamID: value("APPLE_TEAM_ID"),
            appleSignInKeyID: value("APPLE_SIWA_KEY_ID"),
            appleSignInPrivateKey: value("APPLE_SIWA_PRIVATE_KEY"),
            appleTokenEncryptionKey: value("APPLE_TOKEN_ENC_KEY"),
            apnsKeyID: value("APNS_KEY_ID"),
            apnsPrivateKey: value("APNS_PRIVATE_KEY"),
            appStoreIssuerID: value("APPSTORE_ISSUER_ID"),
            appStoreKeyID: value("APPSTORE_KEY_ID"),
            appStorePrivateKey: value("APPSTORE_PRIVATE_KEY"),
            mediaRoot: value("MEDIA_ROOT") ?? (isProduction ? "/data/media" : "./.media"),
            mediaURLSecret: mediaURLSecret ?? (isProduction ? "" : "development-media-url-secret"),
            adminAPIToken: adminAPIToken,
            reportWebhookURL: reportWebhookURL,
            subscriptionRequired: try flag("SUBSCRIPTION_REQUIRED", default: false),
            minimumClientVersion: minimumClientVersion,
            devLoginEnabled: try flag("DEV_LOGIN_ENABLED", default: false),
            dayLength: dayLength,
            allowedBundleIDs: BundleIDs.all,
            rateLimits: try RateLimits(environment: env)
        )
        try validate()
    }

    /// Refuses settings that are only safe in development (spec "개발 로그인": the server must not
    /// start with dev login in production) and secrets that production cannot run without.
    public func validate() throws {
        if let token = adminAPIToken, token.utf8.count < Self.minimumAdminTokenBytes {
            throw ConfigurationError(
                "ADMIN_API_TOKEN must be at least \(Self.minimumAdminTokenBytes) bytes")
        }
        guard isProduction else { return }
        if devLoginEnabled {
            throw ConfigurationError("DEV_LOGIN_ENABLED=true is refused when APP_ENV=production")
        }
        if dayLength != Self.defaultDayLength {
            throw ConfigurationError(
                "TIME_SCALE_DAY_SECONDS is a development setting; production must use 86400")
        }
        if mediaURLSecret.utf8.count < 32 {
            throw ConfigurationError("MEDIA_URL_SECRET must be set (32+ bytes) in production")
        }
        if (jwtSecret?.utf8.count ?? 0) < 32 {
            throw ConfigurationError("JWT_SECRET must be set (32+ bytes) in production")
        }
    }

    /// A configuration for tests: development-only switches off, a scratch media root.
    public static func testing(
        databaseURL: String, mediaRoot: String, dayLength: TimeInterval = defaultDayLength
    ) -> AppConfig {
        AppConfig(
            appEnvironment: .testing,
            databaseURL: databaseURL,
            publicBaseURL: URL(string: "http://localhost:3100")!,
            httpHost: "127.0.0.1",
            httpPort: 3100,
            version: "test",
            jwtSecret: "test-jwt-secret-test-jwt-secret-0000",
            appleTeamID: nil,
            appleSignInKeyID: nil,
            appleSignInPrivateKey: nil,
            appleTokenEncryptionKey: nil,
            apnsKeyID: nil,
            apnsPrivateKey: nil,
            appStoreIssuerID: nil,
            appStoreKeyID: nil,
            appStorePrivateKey: nil,
            mediaRoot: mediaRoot,
            mediaURLSecret: "test-media-url-secret-test-media-url",
            adminAPIToken: "test-admin-token-test-admin-token-0000",
            reportWebhookURL: nil,
            subscriptionRequired: false,
            minimumClientVersion: nil,
            devLoginEnabled: false,
            dayLength: dayLength,
            allowedBundleIDs: BundleIDs.all,
            rateLimits: RateLimits()
        )
    }
}

/// Per-user (and, before sign-in, per-IP) request budgets. Defaults are
/// `PilgrimAPI.RateLimitDefaults`; `RATE_LIMIT_<NAME>=<requests>/<windowSeconds>` overrides one,
/// for example `RATE_LIMIT_POSTS=30/3600`.
public struct RateLimits: Sendable, Equatable {
    public var posts: RateLimitRule
    public var comments: RateLimitRule
    public var uploads: RateLimitRule
    public var reactions: RateLimitRule
    public var reports: RateLimitRule
    public var inviteCreation: RateLimitRule
    public var other: RateLimitRule
    public var unauthenticatedPerIP: RateLimitRule

    public init() {
        posts = RateLimitRule(RateLimitDefaults.posts)
        comments = RateLimitRule(RateLimitDefaults.comments)
        uploads = RateLimitRule(RateLimitDefaults.uploads)
        reactions = RateLimitRule(RateLimitDefaults.reactions)
        reports = RateLimitRule(RateLimitDefaults.reports)
        inviteCreation = RateLimitRule(RateLimitDefaults.inviteCreation)
        other = RateLimitRule(RateLimitDefaults.other)
        unauthenticatedPerIP = RateLimitRule(RateLimitDefaults.unauthenticatedPerIP)
    }

    init(environment env: [String: String]) throws {
        self.init()
        func read(_ name: String, into rule: inout RateLimitRule) throws {
            let key = "RATE_LIMIT_\(name)"
            guard let text = env[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
                return
            }
            guard let parsed = RateLimitRule(text) else {
                throw ConfigurationError("\(key) must look like 30/3600, got \(text)")
            }
            rule = parsed
        }
        try read("POSTS", into: &posts)
        try read("COMMENTS", into: &comments)
        try read("UPLOADS", into: &uploads)
        try read("REACTIONS", into: &reactions)
        try read("REPORTS", into: &reports)
        try read("INVITES", into: &inviteCreation)
        try read("OTHER", into: &other)
        try read("UNAUTHENTICATED", into: &unauthenticatedPerIP)
    }
}

public struct RateLimitRule: Sendable, Hashable {
    public var requests: Int
    public var window: TimeInterval

    public init(requests: Int, window: TimeInterval) {
        self.requests = requests
        self.window = window
    }

    public init(_ rule: RateLimitDefaults.Rule) {
        self.init(requests: rule.requests, window: rule.window)
    }

    /// Parses `<requests>/<windowSeconds>`.
    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let requests = Int(parts[0]), requests > 0,
            let window = TimeInterval(parts[1]), window > 0
        else { return nil }
        self.init(requests: requests, window: window)
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }
}
