import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Auth module — owned by task S1 (openspec/changes/add-private-groups/tasks.md).
///
/// `POST /api/v1/auth/apple|refresh|logout|dev`. Installs `AccessTokenService` as
/// `app.accessTokenVerifier`; `auth/dev` exists only when `app.pilgrimConfig.devLoginEnabled`
/// (`AppConfig.validate` refuses that in production).
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum AuthModule {
    static func register(_ app: Application) throws {
        let services = try AuthServices.make(
            config: app.pilgrimConfig, client: app.client, logger: app.logger)
        app.authServices = services
        app.accessTokenVerifier = services.accessTokens

        let routes = app.pilgrimRoutes
        let auth = routes.v1.grouped("auth")
        auth.post("apple", use: signInWithApple)
        auth.post("refresh", use: refresh)
        routes.authenticated.grouped("auth").post("logout", use: logout)
        if app.pilgrimConfig.devLoginEnabled {
            auth.post("dev", use: devSignIn)
        }
    }

    @Sendable static func signInWithApple(_ req: Request) async throws -> Response {
        let body = try req.content.decode(AppleSignInRequest.self)
        let services = req.application.authServices
        let now = Date()
        let identity = try await services.appleIdentityVerifier.verify(
            identityToken: body.identityToken, bundleID: body.bundleId, rawNonce: body.rawNonce,
            now: now)

        // No Apple refresh token → no sign-in (account deletion must be able to revoke it).
        let exchange: AppleTokenExchange
        do {
            exchange = try await services.appleAuthorization.exchange(
                authorizationCode: body.authorizationCode, clientID: body.bundleId)
        } catch let error as APIError {
            throw error
        } catch {
            req.logger.warning("apple code exchange failed: \(String(describing: error))")
            throw APIError(code: .appleCodeExchangeFailed, message: "code exchange failed")
        }
        if let subject = exchange.subject, subject != identity.subject {
            throw APIError(code: .appleTokenInvalid, message: "code belongs to another user")
        }
        let ciphertext = try services.appleTokenCipher.encrypt(exchange.refreshToken)

        let user = try await AuthStore.findOrCreateUser(appleSub: identity.subject, on: req.db)
        let userID = try user.requireID()
        try await AuthStore.storeAppleToken(
            userID: userID, clientID: body.bundleId, ciphertext: ciphertext, on: req.db)
        let session = try await SessionService.startSession(
            userID: userID, installationID: body.installationId,
            accessTokens: services.accessTokens, on: req.db, now: now)
        return try await sessionResponse(session, user: user, req: req, now: now)
    }

    @Sendable static func refresh(_ req: Request) async throws -> Response {
        let body = try req.content.decode(RefreshRequest.self)
        let now = Date()
        let session = try await SessionService.rotate(
            refreshToken: body.refreshToken, installationID: body.installationId,
            accessTokens: req.application.authServices.accessTokens, on: req.db, now: now)
        guard let user = try await User.find(session.userID, on: req.db) else {
            throw APIError(code: .refreshTokenInvalid, message: "account no longer exists")
        }
        return try await sessionResponse(session, user: user, req: req, now: now)
    }

    /// Always 204: revokes the token's family when it is the caller's and removes the caller's
    /// row for this installation.
    @Sendable static func logout(_ req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(LogoutRequest.self)
        let userID = try req.userID
        try await SessionService.revokeFamily(
            ofRefreshToken: body.refreshToken, userID: userID, on: req.db)
        try await Device.query(on: req.db)
            .filter(\.$installationID == body.installationId)
            .filter(\.$user.$id == userID)
            .delete()
        return .noContent
    }

    static let devUserCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// `POST /auth/dev`: signs in as `dev:<devUser>` without Apple.
    @Sendable static func devSignIn(_ req: Request) async throws -> Response {
        let body = try req.content.decode(DevSignInRequest.self)
        guard (1...64).contains(body.devUser.count),
            body.devUser.allSatisfy({ devUserCharacters.contains($0) })
        else {
            throw APIError.validationFailed(field: "devUser", "devUser must be 1–64 of [A-Za-z0-9._-]")
        }
        guard req.pilgrimConfig.allowedBundleIDs.contains(body.bundleId) else {
            throw APIError.invalidRequest("unknown bundleId")
        }
        let now = Date()
        let user = try await AuthStore.findOrCreateUser(
            appleSub: "dev:\(body.devUser)", on: req.db)
        let session = try await SessionService.startSession(
            userID: try user.requireID(), installationID: body.installationId,
            accessTokens: req.application.authServices.accessTokens, on: req.db, now: now)
        return try await sessionResponse(session, user: user, req: req, now: now)
    }

    static func sessionResponse(_ session: IssuedSession, user: User, req: Request, now: Date)
        async throws -> Response
    {
        let me = try await MeResponseBuilder.response(
            for: user, on: req.db, config: req.pilgrimConfig, now: now)
        return try .pilgrimJSON(
            AuthSessionResponse(
                accessToken: session.accessToken,
                accessTokenExpiresAt: session.accessTokenExpiresAt,
                refreshToken: session.refreshToken,
                refreshTokenExpiresAt: session.refreshTokenExpiresAt, user: me))
    }
}
