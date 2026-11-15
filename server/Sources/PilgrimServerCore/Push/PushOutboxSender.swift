import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// When a failed outbox row is tried again (design.md 10절): 30 seconds, 2 minutes, then
/// 10 minutes after each failure; after the fourth failed attempt the row is marked failed.
public enum PushRetryPolicy {
    public static let delays: [TimeInterval] = [30, 2 * 60, 10 * 60]

    /// `attempts` counts the attempts made so far, including the one that just failed.
    /// nil means give up.
    public static func nextAttempt(afterFailedAttempts attempts: Int, now: Date) -> Date? {
        guard attempts >= 1, attempts <= delays.count else { return nil }
        return now.addingTimeInterval(delays[attempts - 1])
    }
}

/// The `pushOutbox` loop body: sends due `push_outbox` rows to every APNs-registered device of
/// their recipient.
public enum PushOutboxSender {
    public static let batchSize = 100
    /// Concurrent APNs requests in one iteration.
    static let maximumConcurrentSends = 8

    public struct Summary: Equatable, Sendable {
        public var sent = 0
        public var retried = 0
        public var failed = 0
        public var tokensCleared = 0
    }

    struct DeviceTarget: Sendable {
        var deviceID: UUID
        var token: String
        var bundleID: String
        var environment: APNSEnvironment
    }

    struct Due: Sendable {
        var id: UUID
        var payload: PushPayload
        var collapseID: String
        var attempts: Int
        var devices: [DeviceTarget]
    }

    /// One pass over at most `batchSize` due rows.
    @discardableResult
    public static func run(
        on db: any Database, sender: any APNSSending, allowedBundleIDs: Set<String>,
        isProduction: Bool, now: Date, logger: Logger
    ) async throws -> Summary {
        guard sender.isConfigured else {
            return try await handleUnconfigured(
                on: db, isProduction: isProduction, now: now, logger: logger)
        }
        let due = try await loadDue(on: db, allowedBundleIDs: allowedBundleIDs, now: now)
        guard !due.isEmpty else { return Summary() }

        // Send outside any transaction; write the results afterwards.
        var deliveries: [(row: Int, device: DeviceTarget, delivery: APNSDelivery)] = []
        for (index, row) in due.enumerated() {
            for device in row.devices {
                deliveries.append(
                    (
                        index, device,
                        APNSDelivery(
                            deviceToken: device.token, topic: device.bundleID,
                            environment: device.environment, payload: row.payload,
                            collapseID: row.collapseID)
                    ))
            }
        }
        let results = await sendAll(deliveries.map(\.delivery), with: sender)

        var perRow = [[APNSDeliveryResult]](repeating: [], count: due.count)
        var invalidTokens: [UUID: DeviceTarget] = [:]
        for (offset, entry) in deliveries.enumerated() {
            let result = results[offset]
            perRow[entry.row].append(result)
            if case .invalidToken = result { invalidTokens[entry.device.deviceID] = entry.device }
        }

        let rowResults = perRow
        let clearedDevices = Array(invalidTokens.values)
        let summary = try await db.transaction { tx -> Summary in
            var summary = Summary()
            let sql = try PushOutbox.sqlDatabase(tx)
            for device in clearedDevices {
                // Only clear the token we used: the app may have registered a new one meanwhile.
                try await sql.raw(
                    """
                    UPDATE devices SET apns_token = NULL, updated_at = \(bind: now)
                    WHERE id = \(bind: device.deviceID) AND apns_token = \(bind: device.token)
                    """
                ).run()
                summary.tokensCleared += 1
            }
            for (index, row) in due.enumerated() {
                let decision = decide(results: rowResults[index], attempts: row.attempts, now: now)
                try await apply(decision, to: row.id, on: sql, now: now)
                switch decision {
                case .sent: summary.sent += 1
                case .retry: summary.retried += 1
                case .failed: summary.failed += 1
                }
            }
            return summary
        }
        if summary.failed > 0 || summary.retried > 0 || summary.tokensCleared > 0 {
            logger.info(
                "push outbox pass",
                metadata: [
                    "sent": "\(summary.sent)", "retried": "\(summary.retried)",
                    "failed": "\(summary.failed)", "tokensCleared": "\(summary.tokensCleared)",
                ])
        }
        return summary
    }

    enum Decision: Equatable {
        case sent
        case retry(attempts: Int, next: Date, error: String)
        case failed(attempts: Int, error: String)
    }

    /// What to do with a row after one attempt over all of its recipient's devices.
    ///
    /// - Any device asking for a retry (5xx, 429, network) → retry the row; devices that already
    ///   got it see the same `apns-collapse-id`, so the copy replaces itself instead of doubling.
    /// - Otherwise at least one delivery, or nothing to deliver to (no devices, or only invalid
    ///   tokens) → sent.
    /// - Otherwise (every device refused) → failed.
    static func decide(results: [APNSDeliveryResult], attempts: Int, now: Date) -> Decision {
        let attempt = attempts + 1
        let retryErrors = results.compactMap { result -> String? in
            if case .retryLater(let message) = result { return message }
            return nil
        }
        if let error = retryErrors.first {
            if let next = PushRetryPolicy.nextAttempt(afterFailedAttempts: attempt, now: now) {
                return .retry(attempts: attempt, next: next, error: error)
            }
            return .failed(attempts: attempt, error: error)
        }
        let rejections = results.compactMap { result -> String? in
            if case .rejected(let message) = result { return message }
            return nil
        }
        if !rejections.isEmpty, !results.contains(.delivered),
            !results.contains(where: { if case .invalidToken = $0 { true } else { false } })
        {
            return .failed(attempts: attempt, error: rejections[0])
        }
        return .sent
    }

    static func apply(_ decision: Decision, to id: UUID, on sql: any SQLDatabase, now: Date)
        async throws
    {
        switch decision {
        case .sent:
            try await sql.raw(
                """
                UPDATE push_outbox SET sent_at = \(bind: now), attempts = attempts + 1
                WHERE id = \(bind: id)
                """
            ).run()
        case .retry(let attempts, let next, let error):
            try await sql.raw(
                """
                UPDATE push_outbox SET attempts = \(bind: attempts), next_attempt_at = \(bind: next),
                    last_error = \(bind: String(error.prefix(500)))
                WHERE id = \(bind: id)
                """
            ).run()
        case .failed(let attempts, let error):
            try await sql.raw(
                """
                UPDATE push_outbox SET attempts = \(bind: attempts), failed_at = \(bind: now),
                    last_error = \(bind: String(error.prefix(500)))
                WHERE id = \(bind: id)
                """
            ).run()
        }
    }

    private struct DueRow: Decodable {
        var id: UUID
        var recipient_user_id: UUID
        var payload: PushPayload
        var collapse_id: String?
        var attempts: Int
    }

    private struct DeviceRow: Decodable {
        var id: UUID
        var user_id: UUID
        var apns_token: String
        var apns_environment: String
        var bundle_id: String
    }

    static func loadDue(on db: any Database, allowedBundleIDs: Set<String>, now: Date)
        async throws -> [Due]
    {
        let sql = try PushOutbox.sqlDatabase(db)
        let rows = try await sql.raw(
            """
            SELECT id, recipient_user_id, payload, collapse_id, attempts FROM push_outbox
            WHERE sent_at IS NULL AND failed_at IS NULL AND next_attempt_at <= \(bind: now)
            ORDER BY next_attempt_at, id
            LIMIT \(bind: batchSize)
            """
        ).all(decoding: DueRow.self)
        guard !rows.isEmpty else { return [] }

        let recipients = Array(Set(rows.map(\.recipient_user_id)))
        let devices = try await sql.raw(
            """
            SELECT id, user_id, apns_token, apns_environment, bundle_id FROM devices
            WHERE user_id = ANY(\(bind: recipients)) AND apns_token IS NOT NULL
            ORDER BY created_at, id
            """
        ).all(decoding: DeviceRow.self)
        var byUser: [UUID: [DeviceTarget]] = [:]
        for device in devices {
            guard allowedBundleIDs.contains(device.bundle_id),
                let environment = APNSEnvironment(rawValue: device.apns_environment)
            else { continue }
            byUser[device.user_id, default: []].append(
                DeviceTarget(
                    deviceID: device.id, token: device.apns_token, bundleID: device.bundle_id,
                    environment: environment))
        }
        return rows.map { row in
            Due(
                id: row.id, payload: row.payload,
                collapseID: row.collapse_id ?? row.id.pilgrimString, attempts: row.attempts,
                devices: byUser[row.recipient_user_id] ?? [])
        }
    }

    static func sendAll(_ deliveries: [APNSDelivery], with sender: any APNSSending) async
        -> [APNSDeliveryResult]
    {
        guard !deliveries.isEmpty else { return [] }
        var results = [APNSDeliveryResult](
            repeating: .retryLater("not sent"), count: deliveries.count)
        await withTaskGroup(of: (Int, APNSDeliveryResult).self) { group in
            var next = 0
            func addNext() {
                guard next < deliveries.count else { return }
                let index = next
                let delivery = deliveries[index]
                next += 1
                group.addTask { (index, await sender.send(delivery)) }
            }
            for _ in 0..<min(maximumConcurrentSends, deliveries.count) { addNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                addNext()
            }
        }
        return results
    }

    /// No APNs key. Production keeps the rows queued and fails the iteration so the operator
    /// sees it in `worker_heartbeat.last_error`; development and tests drop due rows (marked
    /// failed) so the queue does not grow forever.
    static func handleUnconfigured(
        on db: any Database, isProduction: Bool, now: Date, logger: Logger
    ) async throws -> Summary {
        let sql = try PushOutbox.sqlDatabase(db)
        if isProduction {
            struct CountRow: Decodable { var count: Int }
            let due =
                try await sql.raw(
                    """
                    SELECT count(*)::int AS count FROM push_outbox
                    WHERE sent_at IS NULL AND failed_at IS NULL AND next_attempt_at <= \(bind: now)
                    """
                ).first(decoding: CountRow.self)?.count ?? 0
            guard due == 0 else {
                throw ConfigurationError(
                    "APNs is not configured (APNS_KEY_ID, APNS_PRIVATE_KEY, APPLE_TEAM_ID); "
                        + "\(due) pushes waiting")
            }
            return Summary()
        }
        struct IDRow: Decodable { var id: UUID }
        let dropped = try await sql.raw(
            """
            UPDATE push_outbox SET failed_at = \(bind: now), last_error = 'APNs is not configured'
            WHERE sent_at IS NULL AND failed_at IS NULL AND next_attempt_at <= \(bind: now)
            RETURNING id
            """
        ).all(decoding: IDRow.self)
        if !dropped.isEmpty {
            logger.debug("APNs is not configured; dropped \(dropped.count) pushes")
        }
        var summary = Summary()
        summary.failed = dropped.count
        return summary
    }
}
