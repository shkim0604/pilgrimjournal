import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// Expiry handling (design.md 12절, only while `SUBSCRIPTION_REQUIRED=true`): a subscription
/// that became `expired` or `revoked` and has no `removal_processed_at` takes its owner out of
/// every group (an admin's groups go to a vote, as on leaving) and deletes what they posted —
/// posts, comments, reactions, stickers and photos. Scraps live in each member's own journal and
/// stay. `removal_processed_at` makes it happen once per expiry; resubscribing clears it.
///
/// An owner who is still entitled through another row (a second original transaction) is not
/// removed; the row is only marked.
enum SubscriptionRemovalSweep {
    struct Removal: Equatable, Sendable {
        var subscriptionID: UUID
        var userID: UUID?
        /// false when the owner was still entitled or there was no owner.
        var removedFromGroups: Bool
    }

    @discardableResult
    static func run(
        on db: any Database, dayLength: TimeInterval, now: Date, limit: Int = 100,
        logger: Logger? = nil
    ) async throws -> [Removal] {
        let sql = try PushOutbox.sqlDatabase(db)
        let due = try await sql.raw(
            """
            SELECT id FROM subscriptions
             WHERE status IN ('expired', 'revoked') AND removal_processed_at IS NULL
             ORDER BY updated_at, id
             LIMIT \(bind: limit)
            """
        ).all().map { try $0.decode(column: "id", as: UUID.self) }

        var removals: [Removal] = []
        for id in due {
            if let removal = try await process(id, on: db, dayLength: dayLength, now: now) {
                removals.append(removal)
                if removal.removedFromGroups, let userID = removal.userID {
                    logger?.info(
                        "subscription ended; member removed from groups",
                        metadata: ["user": .string(userID.uuidString)])
                }
            }
        }
        return removals
    }

    /// One row in its own transaction; nil when another worker got there first or the row
    /// changed meanwhile.
    static func process(
        _ subscriptionID: UUID, on db: any Database, dayLength: TimeInterval, now: Date
    ) async throws -> Removal? {
        try await db.transaction { tx in
            let sql = try PushOutbox.sqlDatabase(tx)
            guard
                let row = try await sql.raw(
                    """
                    SELECT id, user_id FROM subscriptions
                     WHERE id = \(bind: subscriptionID)
                       AND status IN ('expired', 'revoked') AND removal_processed_at IS NULL
                     FOR UPDATE SKIP LOCKED
                    """
                ).first()
            else { return nil }
            let userID = try row.decode(column: "user_id", as: UUID?.self)

            var removed = false
            if let userID {
                let rows = try await SubscriptionEntitlement.rows(for: userID, on: tx)
                if !SubscriptionEntitlement.hasActiveSubscription(rows, now: now) {
                    try await removeFromGroups(userID, dayLength: dayLength, on: tx, now: now)
                    removed = true
                }
            }
            try await sql.raw(
                """
                UPDATE subscriptions SET removal_processed_at = \(bind: now), updated_at = \(bind: now)
                 WHERE id = \(bind: subscriptionID)
                """
            ).run()
            return Removal(
                subscriptionID: subscriptionID, userID: userID, removedFromGroups: removed)
        }
    }

    /// Leaves every group (`GroupService.leave`: admin → vote or appointment, last member →
    /// group deleted) and deletes the user's group content. The user, their profile photo,
    /// blocks and hides stay. Call inside a transaction.
    static func removeFromGroups(
        _ userID: UUID, dayLength: TimeInterval, on db: any Database, now: Date
    ) async throws {
        let groupIDs = try await Membership.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
            .map { $0.$group.id }
        for groupID in groupIDs {
            try await GroupService.leave(
                userID, group: groupID, dayLength: dayLength, on: db, now: now)
        }

        let sql = try PushOutbox.sqlDatabase(db)
        // Comments that used one of the user's stickers show "deleted sticker" afterwards.
        try await sql.raw(
            """
            UPDATE comments SET had_sticker = true
             WHERE sticker_id IN (SELECT id FROM stickers WHERE created_by_id = \(bind: userID))
            """
        ).run()
        // Cascades remove reactions with these stickers, and comments, reactions, extensions
        // and photos of these posts; `media_after_delete` queues the files.
        try await sql.raw("DELETE FROM stickers WHERE created_by_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM posts WHERE author_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM comments WHERE author_id = \(bind: userID)").run()
        try await sql.raw("DELETE FROM reactions WHERE user_id = \(bind: userID)").run()
        try await sql.raw(
            "DELETE FROM media WHERE uploader_id = \(bind: userID) AND purpose <> 'profile'"
        ).run()
    }
}

/// The hourly re-check of subscriptions a missed webhook may have left stale (design.md 12절):
/// still `active`, `gracePeriod` or `billingRetry`, `expires_at` more than a day ago and neither
/// updated nor checked for a day. Each is asked of the App Store Server API and set to what
/// Apple answers. Runs whatever `SUBSCRIPTION_REQUIRED` is, so the stored status is right when
/// the flag is turned on; it only changes rows, never memberships.
enum SubscriptionRecheckSweep {
    static let staleAfter: TimeInterval = 86_400

    struct Outcome: Equatable, Sendable {
        var checked: [UUID] = []
        var failed: [UUID] = []
    }

    @discardableResult
    static func run(
        on db: any Database, client: any AppStoreStatusFetching,
        verifier: AppStoreSignedDataVerifier, now: Date, limit: Int = 50, logger: Logger? = nil
    ) async throws -> Outcome {
        let cutoff = now.addingTimeInterval(-staleAfter)
        let rows = try await AppStoreSubscription.query(on: db)
            .filter(\.$status ~~ [.active, .gracePeriod, .billingRetry])
            .filter(\.$expiresAt < cutoff)
            .filter(\.$updatedAt < cutoff)
            .group(.or) { $0.filter(\.$lastCheckedAt == nil).filter(\.$lastCheckedAt < cutoff) }
            .sort(\.$expiresAt)
            .limit(limit)
            .all()

        var outcome = Outcome()
        for row in rows {
            let id = try row.requireID()
            do {
                try await recheck(row, client: client, verifier: verifier, on: db, now: now)
                outcome.checked.append(id)
            } catch {
                outcome.failed.append(id)
                logger?.warning(
                    "subscription re-check failed",
                    metadata: [
                        "subscription": .string(id.uuidString),
                        "error": .string(String(describing: error)),
                    ])
                // Do not ask again for a day.
                try await PushOutbox.sqlDatabase(db).raw(
                    "UPDATE subscriptions SET last_checked_at = \(bind: now) WHERE id = \(bind: id)"
                ).run()
            }
        }
        return outcome
    }

    struct MissingStatus: Error, CustomStringConvertible {
        var description: String { "App Store returned no status for the original transaction" }
    }

    static func recheck(
        _ row: AppStoreSubscription, client: any AppStoreStatusFetching,
        verifier: AppStoreSignedDataVerifier, on db: any Database, now: Date
    ) async throws {
        let response = try await client.subscriptionStatuses(
            originalTransactionID: row.originalTransactionID, bundleID: row.bundleID,
            environment: row.environment)
        guard let item = response.lastTransaction(for: row.originalTransactionID),
            let code = item.status,
            let status = SubscriptionTransition.status(fromAppStoreStatus: code),
            let signedTransaction = item.signedTransactionInfo
        else { throw MissingStatus() }
        let transaction = try await verifier.verifyTransaction(
            signedTransaction, expectedBundleID: row.bundleID)
        guard transaction.originalTransactionID == row.originalTransactionID else {
            throw MissingStatus()
        }
        var entitlementEnd: Date?
        if status == .gracePeriod, let signedRenewal = item.signedRenewalInfo {
            entitlementEnd = try await verifier.verifyRenewalInfo(signedRenewal)
                .gracePeriodExpiresDate
        }
        let update = SubscriptionUpdate.statusCheck(status: status, entitlementEnd: entitlementEnd)
        try await db.transaction { tx in
            _ = try await SubscriptionService.upsert(
                transaction, as: update, owner: .keep, checkedAt: now, on: tx, now: now)
        }
    }
}
