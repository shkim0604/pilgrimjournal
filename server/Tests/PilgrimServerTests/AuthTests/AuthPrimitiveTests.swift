import Crypto
import Foundation
import PilgrimAPI
import Vapor
import XCTest

@testable import PilgrimServerCore

/// Access JWTs, the Apple token cipher, the Apple client secret and refresh token shape.
final class AuthPrimitiveTests: XCTestCase {
    private let service = AccessTokenService(secret: "unit-test-secret-unit-test-secret-00")

    func testAccessTokenRoundTrip() throws {
        let userID = UUID()
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000.75)
        let issued = try service.issue(userID: userID, sessionID: sessionID, now: now)
        XCTAssertEqual(issued.expiresAt, Date(timeIntervalSince1970: 1_800_000_900))
        let user = try service.verify(issued.token, now: now.addingTimeInterval(60))
        XCTAssertEqual(user, AuthenticatedUser(id: userID, sessionID: sessionID))
    }

    func testExpiredAccessTokenIsTokenExpired() throws {
        let now = Date()
        let issued = try service.issue(userID: UUID(), sessionID: UUID(), now: now)
        XCTAssertThrowsError(
            try service.verify(issued.token, now: now.addingTimeInterval(SessionLifetime.accessToken + 1))
        ) { XCTAssertEqual(($0 as? APIError)?.code, .tokenExpired) }
    }

    func testTamperedOrForeignTokenIsUnauthenticated() throws {
        let issued = try service.issue(userID: UUID(), sessionID: UUID())
        var tampered = issued.token
        tampered.removeLast(2)
        tampered += tampered.hasSuffix("A") ? "BB" : "AA"
        let other = AccessTokenService(secret: "another-secret-another-secret-0000")
        let foreign = try other.issue(userID: UUID(), sessionID: UUID()).token
        for token in [tampered, foreign, "garbage", ""] {
            XCTAssertThrowsError(try service.verify(token, now: Date()), token) {
                XCTAssertEqual(($0 as? APIError)?.code, .unauthenticated)
            }
        }
    }

    func testCipherRoundTripAndFormat() throws {
        let cipher = AppleTokenCipher.ephemeral()
        let sealed = try cipher.encrypt("r.apple-refresh-token")
        // 12-byte nonce ‖ ciphertext ‖ 16-byte tag.
        XCTAssertEqual(sealed.count, 12 + "r.apple-refresh-token".utf8.count + 16)
        XCTAssertEqual(try cipher.decrypt(sealed), "r.apple-refresh-token")
        XCTAssertThrowsError(try AppleTokenCipher.ephemeral().decrypt(sealed))
    }

    func testCipherKeyEncodings() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let fromHex = try AppleTokenCipher(encodedKey: hex)
        let fromBase64 = try AppleTokenCipher(encodedKey: bytes.base64EncodedString())
        XCTAssertEqual(try fromBase64.decrypt(try fromHex.encrypt("token")), "token")
        XCTAssertThrowsError(try AppleTokenCipher(encodedKey: "short"))
        XCTAssertThrowsError(
            try AppleTokenCipher(encodedKey: Data(count: 16).base64EncodedString()))
    }

    func testClientSecretIsVerifiableES256() throws {
        let key = P256.Signing.PrivateKey()
        // `.env` files carry the `.p8` on one line with escaped newlines.
        let escaped = key.pemRepresentation.replacingOccurrences(of: "\n", with: "\\n")
        let signer = try AppleClientSecretSigner(
            teamID: "TEAM123456", keyID: "KEY1234567", privateKeyPEM: escaped)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secret = try signer.clientSecret(clientID: BundleIDs.debug, now: now)

        let parts = secret.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try XCTUnwrap(Data(base64URLEncoded: parts[2])))
        XCTAssertTrue(
            key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        let header = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Data(base64URLEncoded: parts[0]))) as? [String: Any]
        XCTAssertEqual(header?["alg"] as? String, "ES256")
        XCTAssertEqual(header?["kid"] as? String, "KEY1234567")
        let claims = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Data(base64URLEncoded: parts[1]))) as? [String: Any]
        XCTAssertEqual(claims?["iss"] as? String, "TEAM123456")
        XCTAssertEqual(claims?["sub"] as? String, BundleIDs.debug)
        XCTAssertEqual(claims?["aud"] as? String, "https://appleid.apple.com")
        XCTAssertEqual(claims?["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(claims?["exp"] as? Int, 1_800_000_300)
    }

    func testClientSecretRejectsBadKey() {
        XCTAssertThrowsError(
            try AppleClientSecretSigner(teamID: "T", keyID: "K", privateKeyPEM: "nope"))
    }

    func testRefreshTokensAreRandomBase64URL() {
        let first = SessionService.generateRefreshToken()
        let second = SessionService.generateRefreshToken()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Data(base64URLEncoded: first)?.count, 32)
        XCTAssertEqual(SessionService.hash(refreshToken: first).count, 32)
    }
}

/// Start-up rules for the auth secrets (`AuthServices.make`).
final class AuthConfigTests: ServerTestCase {
    func testProductionRefusesMissingAppleSecrets() throws {
        var config = AppConfig.testing(databaseURL: "postgres://x@127.0.0.1:1/x", mediaRoot: "/tmp")
        config.appEnvironment = .production
        let logger = Logger(label: "test")
        let client = app.client
        XCTAssertThrowsError(try AuthServices.make(config: config, client: client, logger: logger))
        config.appleTeamID = "TEAM123456"
        config.appleSignInKeyID = "KEY1234567"
        config.appleSignInPrivateKey = P256.Signing.PrivateKey().pemRepresentation
        XCTAssertThrowsError(try AuthServices.make(config: config, client: client, logger: logger))
        config.appleTokenEncryptionKey = Data(count: 32).base64EncodedString()
        XCTAssertNoThrow(try AuthServices.make(config: config, client: client, logger: logger))
    }

    func testDevelopmentFallsBackWithoutSecrets() throws {
        var config = AppConfig.testing(databaseURL: "postgres://x@127.0.0.1:1/x", mediaRoot: "/tmp")
        config.appEnvironment = .development
        config.jwtSecret = nil
        let services = try AuthServices.make(
            config: config, client: app.client, logger: Logger(label: "test"))
        XCTAssertTrue(services.appleAuthorization is UnconfiguredAppleAuthorizationClient)
        let issued = try services.accessTokens.issue(userID: UUID(), sessionID: UUID())
        XCTAssertNoThrow(try services.accessTokens.verify(issued.token, now: Date()))
    }

    func testProductionWithDevLoginIsRefused() throws {
        var config = AppConfig.testing(databaseURL: "postgres://x@127.0.0.1:1/x", mediaRoot: "/tmp")
        config.appEnvironment = .production
        config.devLoginEnabled = true
        XCTAssertThrowsError(try config.validate()) {
            XCTAssertTrue(String(describing: $0).contains("DEV_LOGIN_ENABLED"))
        }
    }
}
