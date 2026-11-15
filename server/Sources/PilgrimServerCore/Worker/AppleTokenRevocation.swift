import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// `appleRevocation` (5 min): revokes the Apple refresh tokens of deleted accounts
/// (`apple_token_revocations`, design.md 13절) with the Auth module's services: the tokens are
/// opened with `AppleTokenCipher` and sent to Apple with `AppleAuthorizationClient.revoke`.
/// Failures back off exponentially from five minutes; after `maximumAttempts` the row stays with
/// its `last_error` for the operator.
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

    private struct DueRow: Decodable {
        var id: UUID
        var clientID: String
        var ciphertext: Data
        var attempts: Int

        enum CodingKeys: String, CodingKey {
            case id
            case clientID = "client_id"
            case ciphertext = "refresh_token_ciphertext"
            case attempts
        }
    }

    @discardableResult
    public static func run(
        on db: any Database, authorization: any AppleAuthorizationClient,
        cipher: AppleTokenCipher, now: Date, logger: Logger
    ) async throws -> Summary {
        let sql = try Sweep.sql(db)
        let due = try await sql.raw(
            """
            SELECT id, client_id, refresh_token_ciphertext, attempts FROM apple_token_revocations
            WHERE completed_at IS NULL AND attempts < \(bind: maximumAttempts)
              AND next_attempt_at <= \(bind: now)
            ORDER BY next_attempt_at, id LIMIT \(bind: batchSize)
            """
        ).all(decoding: DueRow.self)

        var summary = Summary()
        for row in due {
            let attempt = row.attempts + 1
            let token: String
            do {
                token = try cipher.decrypt(row.ciphertext)
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
            do {
                try await authorization.revoke(refreshToken: token, clientID: row.clientID)
                try await sql.raw(
                    """
                    UPDATE apple_token_revocations
                    SET attempts = \(bind: attempt), completed_at = \(bind: now), last_error = NULL
                    WHERE id = \(bind: row.id)
                    """
                ).run()
                summary.revoked += 1
            } catch {
                let message = String(String(describing: error).prefix(500))
                let next = nextAttempt(afterFailedAttempts: attempt, now: now) ?? now
                try await sql.raw(
                    """
                    UPDATE apple_token_revocations
                    SET attempts = \(bind: attempt), next_attempt_at = \(bind: next),
                        last_error = \(bind: message)
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
