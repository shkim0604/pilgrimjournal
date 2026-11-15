import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// `DELETE /me` (design.md 13절), in one transaction:
///
/// 1. every active group the user administers hands over by `AdminVoteRules.start`: no member
///    left → the group is deleted; one → they become admin (`voteDecided` push); more → round 1
///    of an admin vote opens (`voteStarted` push);
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

            var handedToVote: [UUID] = []
            var deleted: [UUID] = []
            let adminGroupIDs = try await sql.raw(
                """
                SELECT id FROM groups
                WHERE admin_id = \(bind: userID) AND status = \(bind: GroupStatus.active.rawValue)
                ORDER BY id FOR UPDATE
                """
            ).all().map { try $0.decode(column: "id", as: UUID.self) }

            for groupID in adminGroupIDs {
                guard let group = try await Group.find(groupID, on: tx) else { continue }
                let others = try await Membership.query(on: tx)
                    .filter(\.$group.$id == groupID)
                    .filter(\.$user.$id != userID)
                    .all()
                    .map { $0.$user.id }
                switch AdminVoteRules.start(remainingMembers: Set(others)) {
                case .deleteGroup:
                    try await group.delete(on: tx)
                    deleted.append(groupID)
                case .appoint(let newAdminID):
                    group.$admin.id = newAdminID
                    try await group.save(on: tx)
                    let name = try await User.find(newAdminID, on: tx)?.displayName ?? ""
                    try await PushOutbox.enqueue(
                        on: tx, groupEvent: .voteDecided(newAdminName: name), groupID: groupID,
                        excluding: [userID], now: now)
                case .openVote(let candidates):
                    group.$admin.id = nil
                    group.status = .voting
                    try await group.save(on: tx)
                    try await AdminVote(
                        groupID: groupID, round: 1, candidateIDs: candidates,
                        eligibleIDs: candidates, startedAt: now,
                        endsAt: now.addingTimeInterval(
                            AdminVoteRules.roundLength(1, dayLength: dayLength))
                    ).create(on: tx)
                    try await PushOutbox.enqueue(
                        on: tx, groupEvent: .voteStarted, groupID: groupID, excluding: [userID],
                        now: now)
                    handedToVote.append(groupID)
                }
            }

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
                deletedAt: now, alreadyDeleted: false, groupsHandedToVote: handedToVote,
                groupsDeleted: deleted)
        }
    }
}
