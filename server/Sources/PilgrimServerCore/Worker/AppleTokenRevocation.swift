import Crypto
import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit
import Vapor

/// Opens Apple refresh tokens stored by the Auth module (S1 `AppleTokenCipher`): AES-256-GCM
/// `combined` representation (12-byte nonce ‖ ciphertext ‖ 16-byte tag) under
/// `APPLE_TOKEN_ENC_KEY`, which is 32 bytes as base64 or as 64 hex digits.
///
/// S1 is not merged yet, so the worker carries this compatible copy; Phase 2 dedupes it.
struct RevocationTokenCipher: Sendable {
    let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Parses `APPLE_TOKEN_ENC_KEY`.
    init(setting: String) throws {
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count == 64, let bytes = Self.hexBytes(text) {
            key = SymmetricKey(data: bytes)
        } else if let data = Data(base64Encoded: text), data.count == 32 {
            key = SymmetricKey(data: data)
        } else {
            throw ConfigurationError(
                "APPLE_TOKEN_ENC_KEY must be 32 bytes as base64 or 64 hex digits")
        }
    }

    func open(_ combined: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        guard let token = String(data: plaintext, encoding: .utf8) else {
            throw APIError(code: .internal, message: "decrypted Apple token is not UTF-8")
        }
        return token
    }

    /// The same format S1 writes (used by tests).
    func seal(_ token: String) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(token.utf8), using: key).combined else {
            throw APIError(code: .internal, message: "AES-GCM produced no combined box")
        }
        return combined
    }

    private static func hexBytes(_ text: String) -> Data? {
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// The Sign in with Apple client secret: an ES256 JWT signed with the `.p8` key, valid for five
/// minutes (design.md 3절).
struct AppleClientSecret {
    static let audience = "https://appleid.apple.com"
    static let lifetime: TimeInterval = 5 * 60

    static func make(
        clientID: String, teamID: String, keyID: String, privateKey: P256.Signing.PrivateKey,
        now: Date
    ) throws -> String {
        struct Header: Encodable {
            let alg = "ES256"
            let kid: String
        }
        struct Claims: Encodable {
            let iss: String
            let iat: Int
            let exp: Int
            let aud: String
            let sub: String
        }
        let issuedAt = Int(now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let header = try encoder.encode(Header(kid: keyID)).base64URLEncodedString()
        let claims = try encoder.encode(
            Claims(
                iss: teamID, iat: issuedAt, exp: issuedAt + Int(lifetime), aud: audience,
                sub: clientID)
        ).base64URLEncodedString()
        let signingInput = "\(header).\(claims)"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        // JWS ES256 uses the raw 64-byte r ‖ s form, not DER.
        return "\(signingInput).\(signature.rawRepresentation.base64URLEncodedString())"
    }
}

public enum AppleRevocationResult: Equatable, Sendable {
    case revoked
    case failed(String)
}

/// Calls Apple's `/auth/revoke`. Tests install a fake with `app.appleTokenRevoker = …`.
public protocol AppleTokenRevoking: Sendable {
    func revoke(refreshToken: String, clientID: String, now: Date) async -> AppleRevocationResult
}

/// Posts to `https://appleid.apple.com/auth/revoke` with the Sign in with Apple key.
public struct LiveAppleTokenRevoker: AppleTokenRevoking {
    public static let endpoint: URI = "https://appleid.apple.com/auth/revoke"

    let client: any Client
    let teamID: String
    let keyID: String
    let privateKey: P256.Signing.PrivateKey

    public func revoke(refreshToken: String, clientID: String, now: Date) async
        -> AppleRevocationResult
    {
        struct Form: Content {
            var client_id: String
            var client_secret: String
            var token: String
            var token_type_hint: String
        }
        struct ErrorBody: Decodable {
            var error: String?
        }
        do {
            let secret = try AppleClientSecret.make(
                clientID: clientID, teamID: teamID, keyID: keyID, privateKey: privateKey,
                now: now)
            let response = try await client.post(Self.endpoint) { request in
                try request.content.encode(
                    Form(
                        client_id: clientID, client_secret: secret, token: refreshToken,
                        token_type_hint: "refresh_token"),
                    as: .urlEncodedForm)
            }
            if response.status == .ok { return .revoked }
            let reason = try? response.content.decode(ErrorBody.self, as: .json).error
            // `invalid_grant`: the token is already expired or revoked, which is the goal.
            if reason == "invalid_grant" { return .revoked }
            return .failed("\(response.status.code) \(reason ?? "")")
        } catch {
            return .failed("network: \(String(describing: error).prefix(200))")
        }
    }
}

extension Application {
    private struct AppleTokenRevokerKey: StorageKey {
        typealias Value = any AppleTokenRevoking
    }

    /// nil when the Sign in with Apple key is not configured.
    public var appleTokenRevoker: (any AppleTokenRevoking)? {
        get { storage[AppleTokenRevokerKey.self] }
        set { storage[AppleTokenRevokerKey.self] = newValue }
    }

    func installLiveAppleTokenRevokerIfConfigured() throws {
        let config = pilgrimConfig
        guard let teamID = config.appleTeamID, let keyID = config.appleSignInKeyID,
            let keyText = config.appleSignInPrivateKey
        else { return }
        let key = try P256.Signing.PrivateKey(pemRepresentation: try PEMSetting.pem(from: keyText))
        appleTokenRevoker = LiveAppleTokenRevoker(
            client: client, teamID: teamID, keyID: keyID, privateKey: key)
    }
}

/// `appleRevocation` (5 min): revokes the Apple refresh tokens of deleted accounts
/// (`apple_token_revocations`, design.md 13절). Failures back off exponentially from five
/// minutes; after `maximumAttempts` the row stays with its `last_error` for the operator.
public enum AppleRevocationSweep {
    public static let batchSize = 50
    public static let maximumAttempts = 10
    static let firstRetryDelay: TimeInterval = 5 * 60
    static let longestRetryDelay: TimeInterval = 24 * 60 * 60

    /// nil once `attempts` (including the one that just failed) reaches `maximumAttempts`.
    public static func nextAttempt(afterFailedAttempts attempts: Int, now: Date) -> Date? {
        guard attempts >= 1, attempts < maximumAttempts else { return nil }
        let delay = min(firstRetryDelay * pow(2, Double(attempts - 1)), longestRetryDelay)
        return now.addingTimeInterval(delay)
    }

    public struct Summary: Equatable, Sendable {
        public var revoked = 0
        public var failed = 0
    }

    @discardableResult
    public static func run(
        on db: any Database, revoker: (any AppleTokenRevoking)?, encryptionKey: String?,
        now: Date, logger: Logger
    ) async throws -> Summary {
        let sql = try Sweep.sql(db)
        struct DueRow: Decodable {
            var id: UUID
            var client_id: String
            var refresh_token_ciphertext: Data
            var attempts: Int
        }
        let due = try await sql.raw(
            """
            SELECT id, client_id, refresh_token_ciphertext, attempts FROM apple_token_revocations
            WHERE completed_at IS NULL AND attempts < \(bind: maximumAttempts)
              AND next_attempt_at <= \(bind: now)
            ORDER BY next_attempt_at, id LIMIT \(bind: batchSize)
            """
        ).all(decoding: DueRow.self)
        guard !due.isEmpty else { return Summary() }
        guard let revoker, let encryptionKey else {
            throw ConfigurationError(
                "Apple token revocation needs APPLE_TEAM_ID, APPLE_SIWA_KEY_ID, "
                    + "APPLE_SIWA_PRIVATE_KEY and APPLE_TOKEN_ENC_KEY; \(due.count) waiting")
        }
        let cipher = try RevocationTokenCipher(setting: encryptionKey)

        var summary = Summary()
        for row in due {
            let attempt = row.attempts + 1
            let token: String
            do {
                token = try cipher.open(row.refresh_token_ciphertext)
            } catch {
                // Retrying cannot fix a wrong key or a damaged row.
                try await sql.raw(
                    """
                    UPDATE apple_token_revocations
                    SET attempts = \(bind: maximumAttempts), last_error = 'cannot decrypt'
                    WHERE id = \(bind: row.id)
                    """
                ).run()
                logger.error("cannot decrypt Apple refresh token", metadata: ["id": "\(row.id)"])
                summary.failed += 1
                continue
            }
            switch await revoker.revoke(refreshToken: token, clientID: row.client_id, now: now) {
            case .revoked:
                try await sql.raw(
                    """
                    UPDATE apple_token_revocations
                    SET attempts = \(bind: attempt), completed_at = \(bind: now), last_error = NULL
                    WHERE id = \(bind: row.id)
                    """
                ).run()
                summary.revoked += 1
            case .failed(let message):
                let next =
                    nextAttempt(afterFailedAttempts: attempt, now: now) ?? now
                try await sql.raw(
                    """
                    UPDATE apple_token_revocations
                    SET attempts = \(bind: attempt), next_attempt_at = \(bind: next),
                        last_error = \(bind: String(message.prefix(500)))
                    WHERE id = \(bind: row.id)
                    """
                ).run()
                if attempt >= maximumAttempts {
                    logger.error(
                        "giving up on Apple token revocation",
                        metadata: ["id": "\(row.id)", "error": "\(message)"])
                }
                summary.failed += 1
            }
        }
        return summary
    }
}
