import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Advisory-lock keys of every worker loop (the second key of
/// `pg_try_advisory_lock(WorkerJob.lockNamespace, key)`). Keep them unique: the registry refuses
/// a duplicate at start-up. Keys for loops owned by other modules are reserved here so parallel
/// tasks do not collide.
public enum WorkerLockKey {
    /// `worker` — the built-in process heartbeat (`WorkerJob.processHeartbeat`).
    public static let processHeartbeat: Int32 = 1
    /// `pushOutbox` (Push module, 5 s).
    public static let pushOutbox: Int32 = 10
    /// `expiry` (60 s).
    public static let expiry: Int32 = 11
    /// `mediaFiles` (60 s).
    public static let mediaFiles: Int32 = 12
    /// `votes` (60 s).
    public static let votes: Int32 = 13
    /// `appleRevocation` (5 min).
    public static let appleRevocation: Int32 = 14
    /// `invites` (1 h).
    public static let invites: Int32 = 15
    /// `retention` (1 h).
    public static let retention: Int32 = 16
    /// Reserved for the `dailyReport` loop (S7, DailyReport module, 60 s).
    public static let dailyReport: Int32 = 20
    /// Reserved for the `subscriptions` loop (S8, Subscriptions module, 10 min).
    public static let subscriptions: Int32 = 21
}

/// Loop periods from design.md "worker". Loop intervals never scale with
/// `TIME_SCALE_DAY_SECONDS`.
public enum WorkerInterval {
    public static let pushOutbox: Duration = .seconds(5)
    public static let expiry: Duration = .seconds(60)
    public static let mediaFiles: Duration = .seconds(60)
    public static let votes: Duration = .seconds(60)
    public static let appleRevocation: Duration = .seconds(5 * 60)
    public static let invites: Duration = .seconds(60 * 60)
    public static let retention: Duration = .seconds(60 * 60)

    /// `/api/health` calls the worker unhealthy when any loop has not beaten for two minutes
    /// (`WorkerHealth.staleAfter`), so a loop whose period is longer still wakes (and beats) this
    /// often and only does its work once the period has passed.
    public static let maximumTick: Duration = .seconds(60)
}

extension WorkerJob {
    /// A job that does `run` at most once per `period` but iterates — and so writes
    /// `worker_heartbeat` — at least every `WorkerInterval.maximumTick`.
    ///
    /// The last run time lives in process memory: a restarted worker runs the job on its first
    /// iteration, which is fine for the idempotent clean-ups that use this. Time comes from
    /// `WorkerContext.now`, so tests drive it with the runner's clock.
    public static func periodic(
        name: String, lockKey: Int32, period: Duration,
        run: @escaping @Sendable (WorkerContext) async throws -> Void
    ) -> WorkerJob {
        let tick = min(period, WorkerInterval.maximumTick)
        guard period > tick else {
            return WorkerJob(name: name, lockKey: lockKey, interval: period, run: run)
        }
        let gate = PeriodGate(period: period.timeInterval)
        return WorkerJob(name: name, lockKey: lockKey, interval: tick) { context in
            guard gate.isDue(at: context.now) else { return }
            try await run(context)
            gate.markRan(at: context.now)
        }
    }
}

/// Remembers when a periodic job last finished successfully.
final class PeriodGate: Sendable {
    let period: TimeInterval
    private let lastRun = NIOLockedValueBox<Date?>(nil)

    init(period: TimeInterval) {
        self.period = period
    }

    func isDue(at now: Date) -> Bool {
        lastRun.withLockedValue { last in
            guard let last else { return true }
            return now.timeIntervalSince(last) >= period || now < last
        }
    }

    func markRan(at now: Date) {
        lastRun.withLockedValue { $0 = now }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
