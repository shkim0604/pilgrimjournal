import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// `DELETE /me` (design.md 13절), in one transaction:
///
/// 1. every group the user administers is handed over (`GroupService.handOverAdminGroups`, the
///    same rules as leaving: no member left → deleted, one → admin, more → round 1 of a vote);
/// 2. the user's Apple refresh tokens move to `apple_token_revocations`;
/// 3. the `users` row is deleted and the database cascades the rest.
///
/// Idempotent: a user who is already gone gets `alreadyDeleted: true`.
public enum AccountDeletion {
    public static func delete(
        userID: UUID, on db: any Database, dayLength: TimeInterval, now: Date = Date()
    ) async throws -> AccountDeletionResponse {
        try await db.transaction { tx in
            let sql = try PushOutbox.sqlDatabase(tx)
            guard
                try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE")
                    .first() != nil
            else {
                return AccountDeletionResponse(deletedAt: nil, alreadyDeleted: true)
            }

            let handOver = try await GroupService.handOverAdminGroups(
                of: userID, dayLength: dayLength, on: tx, now: now)

            let appleTokens = try await AppleToken.query(on: tx)
                .filter(\.$user.$id == userID)
                .all()
            for token in appleTokens {
                try await AppleTokenRevocation(
                    clientID: token.clientID, ciphertext: token.refreshTokenCiphertext,
                    nextAttemptAt: now
                ).create(on: tx)
            }

            try await sql.raw("DELETE FROM users WHERE id = \(bind: userID)").run()
            return AccountDeletionResponse(
                deletedAt: now, alreadyDeleted: false, groupsHandedToVote: handOver.handedToVote,
                groupsDeleted: handOver.deleted)
        }
    }
}
