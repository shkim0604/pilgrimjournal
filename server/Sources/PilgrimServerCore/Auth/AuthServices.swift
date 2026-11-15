import Crypto
import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// The services sign-in uses, built by `AuthModule.register` from `AppConfig`. Tests replace
/// parts after `configure` (a fake JWKS source, a fake Apple token endpoint).
public struct AuthServices: Sendable {
    public var appleIdentityVerifier: AppleIdentityTokenVerifier
    public var appleAuthorization: any AppleAuthorizationClient
    /// Encrypts Apple refresh tokens (`APPLE_TOKEN_ENC_KEY`); S5's revocation worker decrypts.
    public var appleTokenCipher: AppleTokenCipher
    public var accessTokens: AccessTokenService

    public init(
        appleIdentityVerifier: AppleIdentityTokenVerifier,
        appleAuthorization: any AppleAuthorizationClient, appleTokenCipher: AppleTokenCipher,
        accessTokens: AccessTokenService
    ) {
        self.appleIdentityVerifier = appleIdentityVerifier
        self.appleAuthorization = appleAuthorization
        self.appleTokenCipher = appleTokenCipher
        self.accessTokens = accessTokens
    }

    /// Reads the Apple and JWT secrets. Production refuses to start without them; elsewhere a
    /// missing JWT secret or encryption key becomes a random per-process value and a missing
    /// Sign in with Apple key makes every code exchange fail with 502.
    public static func make(config: AppConfig, client: any Client, logger: Logger) throws
        -> AuthServices
    {
        let jwtSecret: String
        if let secret = config.jwtSecret {
            jwtSecret = secret
        } else if config.isProduction {
            throw ConfigurationError("JWT_SECRET is required in production")
        } else {
            logger.warning("JWT_SECRET is not set; using a random secret for this process")
            jwtSecret = SymmetricKey(size: .bits256).withUnsafeBytes {
                Data($0).base64EncodedString()
            }
        }

        let cipher: AppleTokenCipher
        if let key = config.appleTokenEncryptionKey {
            cipher = try AppleTokenCipher(encodedKey: key)
        } else if config.isProduction {
            throw ConfigurationError("APPLE_TOKEN_ENC_KEY is required in production")
        } else {
            cipher = .ephemeral()
        }

        let appleAuthorization: any AppleAuthorizationClient
        if let teamID = config.appleTeamID, let keyID = config.appleSignInKeyID,
            let privateKey = config.appleSignInPrivateKey
        {
            appleAuthorization = LiveAppleAuthorizationClient(
                client: client,
                secretSigner: try AppleClientSecretSigner(
                    teamID: teamID, keyID: keyID, privateKeyPEM: privateKey),
                logger: logger)
        } else if config.isProduction {
            throw ConfigurationError(
                "APPLE_TEAM_ID, APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY are required in production"
            )
        } else {
            appleAuthorization = UnconfiguredAppleAuthorizationClient()
        }

        return AuthServices(
            appleIdentityVerifier: AppleIdentityTokenVerifier(
                cache: AppleJWKSCache(source: LiveAppleJWKSSource(client: client)),
                allowedBundleIDs: config.allowedBundleIDs),
            appleAuthorization: appleAuthorization,
            appleTokenCipher: cipher,
            accessTokens: AccessTokenService(secret: jwtSecret))
    }
}

extension Application {
    private struct AuthServicesKey: StorageKey {
        typealias Value = AuthServices
    }

    /// Set by `AuthModule.register`.
    public var authServices: AuthServices {
        get {
            guard let services = storage[AuthServicesKey.self] else {
                fatalError("AuthModule.register has not run")
            }
            return services
        }
        set { storage[AuthServicesKey.self] = newValue }
    }
}

/// Users and Apple tokens as sign-in writes them.
enum AuthStore {
    /// Finds the user for `appleSub`, creating an empty one (no display name) the first time.
    static func findOrCreateUser(appleSub: String, on db: any Database) async throws -> User {
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            INSERT INTO users (id, apple_sub) VALUES (\(bind: UUID()), \(bind: appleSub))
            ON CONFLICT (apple_sub) DO NOTHING
            """
        ).run()
        guard let user = try await User.query(on: db).filter(\.$appleSub == appleSub).first()
        else { throw APIError(code: .internal, message: "user upsert failed") }
        return user
    }

    /// Overwrites the user's Apple refresh token for this client ID.
    static func storeAppleToken(
        userID: UUID, clientID: String, ciphertext: Data, on db: any Database
    ) async throws {
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            INSERT INTO apple_tokens (id, user_id, client_id, refresh_token_ciphertext)
            VALUES (\(bind: UUID()), \(bind: userID), \(bind: clientID),
                decode(\(bind: ciphertext.base64EncodedString()), 'base64'))
            ON CONFLICT (user_id, client_id) DO UPDATE SET
                refresh_token_ciphertext = EXCLUDED.refresh_token_ciphertext,
                updated_at = now()
            """
        ).run()
    }
}
