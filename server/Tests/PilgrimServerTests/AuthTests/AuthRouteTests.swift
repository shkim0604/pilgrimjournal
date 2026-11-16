import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// `POST /auth/apple|refresh|logout` against Postgres, with a fake JWKS and Apple endpoint.
final class AuthRouteTests: DatabaseTestCase {
    static let appleRefreshToken = "r.fake-apple-refresh-token"
    static let appleSub = "001234.apple-test-user"

    override func setUp() async throws {
        try await super.setUp()
        app.authServices.appleIdentityVerifier = AppleIdentityTokenVerifier(
            cache: AppleJWKSCache(source: FakeJWKSSource()))
        app.authServices.appleAuthorization = FakeAppleAuthorization(
            outcome: .succeed(refreshToken: Self.appleRefreshToken, subject: Self.appleSub))
        // The harness installs `TestAccessTokens`; these tests use the real JWTs.
        app.accessTokenVerifier = app.authServices.accessTokens
    }

    private func clientHeaders(bearer: String? = nil) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: ClientHeader.name, value: Self.clientHeaderValue)
        if let bearer { headers.bearerAuthorization = BearerAuthorization(token: bearer) }
        return headers
    }

    private func signInRequest(installationID: UUID = UUID()) throws -> AppleSignInRequest {
        AppleSignInRequest(
            identityToken: try AppleTestTokens.token(sub: Self.appleSub),
            authorizationCode: "c.fake-code", rawNonce: AppleTestTokens.rawNonce,
            bundleId: BundleIDs.release, installationId: installationID)
    }

    private func signIn(_ body: AppleSignInRequest) async throws -> AuthSessionResponse {
        var session: AuthSessionResponse?
        try await app.test(
            .POST, "api/v1/auth/apple", headers: clientHeaders(),
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            session = try decode(AuthSessionResponse.self, from: res)
        }
        return try XCTUnwrap(session)
    }

    private func refresh(_ token: String, installationID: UUID) async throws -> (
        status: HTTPStatus, session: AuthSessionResponse?, error: APIError?
    ) {
        var result: (HTTPStatus, AuthSessionResponse?, APIError?) = (.internalServerError, nil, nil)
        try await app.test(
            .POST, "api/v1/auth/refresh", headers: clientHeaders(),
            beforeRequest: { req in
                try req.content.encode(
                    RefreshRequest(refreshToken: token, installationId: installationID),
                    as: .json)
            }
        ) { res async throws in
            if res.status == .ok {
                result = (res.status, try decode(AuthSessionResponse.self, from: res), nil)
            } else {
                result = (res.status, nil, try errorBody(res))
            }
        }
        return result
    }

    private func rotated(_ token: String, installationID: UUID) async throws
        -> AuthSessionResponse
    {
        let result = try await refresh(token, installationID: installationID)
        return try XCTUnwrap(result.session, result.error?.message ?? "")
    }

    // MARK: - Sign in with Apple

    func testSignInCreatesEmptyUserAndStoresEncryptedAppleToken() async throws {
        let session = try await signIn(try signInRequest())
        XCTAssertFalse(session.user.profileComplete)
        XCTAssertNil(session.user.displayName)
        XCTAssertEqual(session.user.entitlement, .notRequired)

        let user = try await unwrapAsync(
            try await User.query(on: db).filter(\.$appleSub == Self.appleSub).first())
        XCTAssertEqual(session.user.id, user.id)
        let stored = try await AppleToken.query(on: db).all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.clientID, BundleIDs.release)
        XCTAssertEqual(
            try app.authServices.appleTokenCipher.decrypt(
                try XCTUnwrap(stored.first)
                    .refreshTokenCiphertext),
            Self.appleRefreshToken)

        // The access token works on an authenticated route.
        try await app.test(.GET, "api/v1/me", headers: clientHeaders(bearer: session.accessToken)) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(try decode(MeResponse.self, from: res).id, user.id)
        }
    }

    func testSecondSignInReusesUserAndOverwritesAppleToken() async throws {
        let first = try await signIn(try signInRequest())
        app.authServices.appleAuthorization = FakeAppleAuthorization(
            outcome: .succeed(refreshToken: "r.second", subject: Self.appleSub))
        let second = try await signIn(try signInRequest())
        XCTAssertEqual(first.user.id, second.user.id)
        let users = try await User.query(on: db).count()
        XCTAssertEqual(users, 1)
        let stored = try await AppleToken.query(on: db).all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            try app.authServices.appleTokenCipher.decrypt(stored[0].refreshTokenCiphertext),
            "r.second")
    }

    func testFailedCodeExchangeIs502AndCreatesNoUser() async throws {
        app.authServices.appleAuthorization = FakeAppleAuthorization(outcome: .httpFailure)
        let body = try signInRequest()
        try await app.test(
            .POST, "api/v1/auth/apple", headers: clientHeaders(),
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async throws in
            XCTAssertEqual(res.status.code, 502)
            XCTAssertEqual(try errorBody(res).code, .appleCodeExchangeFailed)
        }
        let users = try await User.query(on: db).count()
        XCTAssertEqual(users, 0)
    }

    func testCodeForAnotherAppleUserIsRefused() async throws {
        app.authServices.appleAuthorization = FakeAppleAuthorization(
            outcome: .succeed(refreshToken: "r.x", subject: "someone-else"))
        let body = try signInRequest()
        try await app.test(
            .POST, "api/v1/auth/apple", headers: clientHeaders(),
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
            XCTAssertEqual(try errorBody(res).code, .appleTokenInvalid)
        }
    }

    func testNonceMismatchIs401() async throws {
        var body = try signInRequest()
        body.rawNonce = "a-different-nonce"
        try await app.test(
            .POST, "api/v1/auth/apple", headers: clientHeaders(),
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
            XCTAssertEqual(try errorBody(res).code, .appleNonceMismatch)
        }
    }

    // MARK: - Refresh

    func testRefreshRotatesWithinFamily() async throws {
        let installation = UUID()
        let first = try await signIn(try signInRequest(installationID: installation))
        let rotated = try await refresh(first.refreshToken, installationID: installation)
        XCTAssertEqual(rotated.status, .ok)
        let second = try XCTUnwrap(rotated.session)
        XCTAssertNotEqual(second.refreshToken, first.refreshToken)

        let rows = try await RefreshToken.query(on: db).all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.familyID)).count, 1)
        let old = try XCTUnwrap(
            rows.first { $0.tokenHash == SessionService.hash(refreshToken: first.refreshToken) })
        XCTAssertNotNil(old.usedAt)
        XCTAssertNotNil(old.replacedByID)

        let third = try await refresh(second.refreshToken, installationID: installation)
        XCTAssertEqual(third.status, .ok)
    }

    func testRetryFromSameInstallationWithinGraceRotatesAgain() async throws {
        let installation = UUID()
        let first = try await signIn(try signInRequest(installationID: installation))
        let lost = try await rotated(first.refreshToken, installationID: installation)
        // The app never saw `lost` and retries with the old token.
        let retry = try await refresh(first.refreshToken, installationID: installation)
        XCTAssertEqual(retry.status, .ok)
        let replacement = try XCTUnwrap(retry.session)
        XCTAssertNotEqual(replacement.refreshToken, lost.refreshToken)
        // The lost token is revoked; the new one works.
        let lostAgain = try await refresh(lost.refreshToken, installationID: installation)
        XCTAssertEqual(lostAgain.error?.code, .refreshTokenInvalid)
        let next = try await refresh(replacement.refreshToken, installationID: installation)
        XCTAssertEqual(next.status, .ok)
    }

    func testReuseRevokesWholeFamily() async throws {
        let installation = UUID()
        let first = try await signIn(try signInRequest(installationID: installation))
        let second = try await rotated(first.refreshToken, installationID: installation)
        // Someone else replays the old token.
        let replay = try await refresh(first.refreshToken, installationID: UUID())
        XCTAssertEqual(replay.status, .unauthorized)
        XCTAssertEqual(replay.error?.code, .refreshTokenReused)
        // The revocation committed: the legitimate token is dead too.
        let afterwards = try await refresh(second.refreshToken, installationID: installation)
        XCTAssertEqual(afterwards.error?.code, .refreshTokenInvalid)
        let live = try await RefreshToken.query(on: db).filter(\.$revokedAt == nil).count()
        XCTAssertEqual(live, 0)
    }

    func testReuseAfterReplacementWasUsedIsTheft() async throws {
        let installation = UUID()
        let first = try await signIn(try signInRequest(installationID: installation))
        let second = try await rotated(first.refreshToken, installationID: installation)
        _ = try await rotated(second.refreshToken, installationID: installation)
        let replay = try await refresh(first.refreshToken, installationID: installation)
        XCTAssertEqual(replay.error?.code, .refreshTokenReused)
    }

    func testReuseAfterGraceWindowIsTheft() async throws {
        let installation = UUID()
        let first = try await signIn(try signInRequest(installationID: installation))
        _ = try await rotated(first.refreshToken, installationID: installation)
        let old = try await unwrapAsync(
            try await RefreshToken.query(on: db)
                .filter(\.$tokenHash == SessionService.hash(refreshToken: first.refreshToken))
                .first())
        old.usedAt = Date().addingTimeInterval(-(SessionLifetime.refreshRetryGrace + 5))
        try await old.save(on: db)
        let replay = try await refresh(first.refreshToken, installationID: installation)
        XCTAssertEqual(replay.error?.code, .refreshTokenReused)
    }

    func testUnknownAndExpiredTokensAreInvalid() async throws {
        let unknown = try await refresh("bm90LWEtdG9rZW4", installationID: UUID())
        XCTAssertEqual(unknown.error?.code, .refreshTokenInvalid)

        let installation = UUID()
        let session = try await signIn(try signInRequest(installationID: installation))
        try await RefreshToken.query(on: db)
            .set(\.$expiresAt, to: Date().addingTimeInterval(-1))
            .update()
        let expired = try await refresh(session.refreshToken, installationID: installation)
        XCTAssertEqual(expired.error?.code, .refreshTokenInvalid)
    }

    // MARK: - Logout

    func testLogoutRevokesFamilyAndRemovesDevice() async throws {
        let installation = UUID()
        let session = try await signIn(try signInRequest(installationID: installation))
        try await Device(
            userID: session.user.id, installationID: installation, apnsToken: "abcd",
            apnsEnvironment: .sandbox, bundleID: BundleIDs.release, platform: .ios
        ).create(on: db)

        try await app.test(
            .POST, "api/v1/auth/logout", headers: clientHeaders(bearer: session.accessToken),
            beforeRequest: { req in
                try req.content.encode(
                    LogoutRequest(refreshToken: session.refreshToken, installationId: installation),
                    as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        let devices = try await Device.query(on: db).count()
        XCTAssertEqual(devices, 0)
        let after = try await refresh(session.refreshToken, installationID: installation)
        XCTAssertEqual(after.error?.code, .refreshTokenInvalid)
    }

    func testLogoutIgnoresSomeoneElsesToken() async throws {
        let victim = try await signIn(try signInRequest())
        let other = try await fixtures.user("다른 사람")
        let otherSession = try await SessionService.startSession(
            userID: try other.requireID(), installationID: UUID(),
            accessTokens: app.authServices.accessTokens, on: db)

        try await app.test(
            .POST, "api/v1/auth/logout", headers: clientHeaders(bearer: otherSession.accessToken),
            beforeRequest: { req in
                try req.content.encode(
                    LogoutRequest(refreshToken: victim.refreshToken, installationId: UUID()),
                    as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        let live = try await RefreshToken.query(on: db)
            .filter(\.$user.$id == victim.user.id)
            .filter(\.$revokedAt == nil)
            .count()
        XCTAssertEqual(live, 1)
    }

    func testExpiredAccessTokenIs401TokenExpired() async throws {
        let user = try await fixtures.user()
        let issued = try app.authServices.accessTokens.issue(
            userID: try user.requireID(), sessionID: UUID(),
            now: Date().addingTimeInterval(-SessionLifetime.accessToken - 60))
        try await app.test(.GET, "api/v1/me", headers: clientHeaders(bearer: issued.token)) {
            res async throws in
            XCTAssertEqual(res.status, .unauthorized)
            XCTAssertEqual(try errorBody(res).code, .tokenExpired)
        }
    }
}

/// `POST /auth/dev` with `DEV_LOGIN_ENABLED=true`.
final class DevLoginRouteTests: DatabaseTestCase {
    override func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        var config = AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot)
        config.devLoginEnabled = true
        return config
    }

    private func devSignIn(_ name: String) async throws -> AuthSessionResponse {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: ClientHeader.name, value: Self.clientHeaderValue)
        var session: AuthSessionResponse?
        try await app.test(
            .POST, "api/v1/auth/dev", headers: headers,
            beforeRequest: { req in
                try req.content.encode(
                    DevSignInRequest(
                        devUser: name, bundleId: BundleIDs.debug, installationId: UUID()),
                    as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            session = try decode(AuthSessionResponse.self, from: res)
        }
        return try XCTUnwrap(session)
    }

    func testDevLoginCreatesAndReusesDevUser() async throws {
        let first = try await devSignIn("alice")
        let second = try await devSignIn("alice")
        XCTAssertEqual(first.user.id, second.user.id)
        let user = try await unwrapAsync(try await User.find(first.user.id, on: db))
        XCTAssertEqual(user.appleSub, "dev:alice")
        XCTAssertNoThrow(
            try app.authServices.accessTokens.verify(first.accessToken, now: Date()))
    }
}

/// Without `DEV_LOGIN_ENABLED` the route does not exist (no database needed).
final class DevLoginDisabledTests: ServerTestCase {
    func testDevLoginIsNotRegistered() async throws {
        try await app.test(
            .POST, "api/v1/auth/dev", headers: try headers(),
            beforeRequest: { req in
                try req.content.encode(
                    DevSignInRequest(
                        devUser: "alice", bundleId: BundleIDs.debug, installationId: UUID()),
                    as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
    }
}
