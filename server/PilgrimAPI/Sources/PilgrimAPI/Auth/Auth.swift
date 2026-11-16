import Foundation

/// `POST /auth/apple` (no auth).
public struct AppleSignInRequest: Equatable, Sendable, Codable {
    public var identityToken: String
    public var authorizationCode: String
    /// The 32-byte random nonce; the Apple request carried `SHA256(rawNonce)` in lowercase hex.
    public var rawNonce: String
    public var bundleId: String
    public var installationId: UUID

    public init(
        identityToken: String, authorizationCode: String, rawNonce: String, bundleId: String,
        installationId: UUID
    ) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.rawNonce = rawNonce
        self.bundleId = bundleId
        self.installationId = installationId
    }
}

/// `POST /auth/refresh` (no auth).
public struct RefreshRequest: Equatable, Sendable, Codable {
    public var refreshToken: String
    public var installationId: UUID

    public init(refreshToken: String, installationId: UUID) {
        self.refreshToken = refreshToken
        self.installationId = installationId
    }
}

/// `POST /auth/logout` → 204. Revokes the refresh family and deletes this device row.
public struct LogoutRequest: Equatable, Sendable, Codable {
    public var refreshToken: String
    public var installationId: UUID

    public init(refreshToken: String, installationId: UUID) {
        self.refreshToken = refreshToken
        self.installationId = installationId
    }
}

/// `POST /auth/dev` — registered only when `DEV_LOGIN_ENABLED=true`. `apple_sub = dev:<devUser>`.
public struct DevSignInRequest: Equatable, Sendable, Codable {
    public var devUser: String
    public var bundleId: String
    public var installationId: UUID

    public init(devUser: String, bundleId: String, installationId: UUID) {
        self.devUser = devUser
        self.bundleId = bundleId
        self.installationId = installationId
    }
}

/// A new group session (sign-in or refresh).
public struct AuthSessionResponse: Equatable, Sendable, Codable {
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    public var refreshTokenExpiresAt: Date
    public var user: MeResponse

    public init(
        accessToken: String, accessTokenExpiresAt: Date, refreshToken: String,
        refreshTokenExpiresAt: Date, user: MeResponse
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.user = user
    }
}

/// Session token lifetimes (design.md 3절).
public enum SessionLifetime {
    public static let accessToken: TimeInterval = 15 * 60
    public static let refreshToken: TimeInterval = 90 * 86_400
    /// A reused refresh token from the same installation within this window is treated as a
    /// retry of a lost response, not theft.
    public static let refreshRetryGrace: TimeInterval = 30
}
