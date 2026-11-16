import Fluent
import Foundation
import Logging
import NIOConcurrencyHelpers
import PilgrimAPI
import SQLKit
import Vapor

/// One polling loop of the `worker` process (design.md "worker").
///
/// Modules register jobs from their `register(_:)`:
/// ```swift
/// app.workerJobs.register(
///     WorkerJob(name: "expiry", lockKey: 2, interval: .seconds(60)) { context in
///         try await ExpirySweep.run(on: context.db, now: context.now)
///     })
/// ```
/// Each iteration runs on one pooled connection that holds
/// `pg_try_advisory_lock(WorkerJob.lockNamespace, lockKey)`, so a second worker process never runs
/// the same loop at the same time; afterwards `worker_heartbeat` is updated (`/api/health`).
/// A job that wants several transactions opens them itself (`context.db.transaction`).
public struct WorkerJob: Sendable {
    public let name: String
    /// Unique per job (the second key of the advisory lock).
    public let lockKey: Int32
    public let interval: Duration
    public let run: @Sendable (WorkerContext) async throws -> Void

    /// The first key of every worker advisory lock, so the locks cannot collide with others.
    public static let lockNamespace: Int32 = 0x5049_4C47 // "PILG"

    public init(
        name: String, lockKey: Int32, interval: Duration,
        run: @escaping @Sendable (WorkerContext) async throws -> Void
    ) {
        self.name = name
        self.lockKey = lockKey
        self.interval = interval
        self.run = run
    }
}

/// What a job iteration gets.
public struct WorkerContext: Sendable {
    /// One connection, holding this job's advisory lock for the iteration.
    public let db: any Database
    public let application: Application
    public let logger: Logger
    /// The iteration's clock reading; use it instead of `Date()` so tests can drive time.
    public let now: Date

    public var config: AppConfig { application.pilgrimConfig }
}

/// The jobs the `worker` command runs. Lock keys and names must be unique.
public final class WorkerJobRegistry: Sendable {
    private let storage = NIOLockedValueBox<[WorkerJob]>([])

    public init() {}

    public func register(_ job: WorkerJob) {
        storage.withLockedValue { jobs in
            precondition(
                !jobs.contains { $0.name == job.name || $0.lockKey == job.lockKey },
                "worker job \(job.name) (lock \(job.lockKey)) is registered twice")
            jobs.append(job)
        }
    }

    public var jobs: [WorkerJob] { storage.withLockedValue { $0 } }

    public var names: [String] { jobs.map(\.name) }
}

/// Runs registered jobs on their intervals until cancelled.
public struct WorkerRunner: Sendable {
    public enum IterationResult: Equatable, Sendable {
        case ran
        case failed(String)
        /// Another worker holds the lock; nothing ran and no heartbeat was written.
        case skippedLocked
    }

    let application: Application
    let clock: @Sendable () -> Date

    public init(application: Application, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.application = application
        self.clock = clock
    }

    /// Runs every job in its own task until the surrounding task is cancelled.
    public func run(jobs: [WorkerJob]) async {
        application.logger.info(
            "worker starting", metadata: ["jobs": .string(jobs.map(\.name).joined(separator: ","))])
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask { await loop(job) }
            }
        }
        application.logger.info("worker stopped")
    }

    private func loop(_ job: WorkerJob) async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            _ = await runOnce(job)
            let next = started.advanced(by: job.interval)
            do {
                try await Task.sleep(until: next, clock: .continuous)
            } catch {
                return // cancelled
            }
        }
    }

    /// One iteration: lock, run, heartbeat, unlock. Errors are logged and recorded, never thrown.
    @discardableResult
    public func runOnce(_ job: WorkerJob) async -> IterationResult {
        let logger = Logger(label: "pilgrim.worker.\(job.name)")
        let database = application.db
        do {
            return try await database.withConnection { connection in
                let sql = try Self.sql(connection)
                guard try await Self.tryLock(job, on: sql) else { return .skippedLocked }
                var result = IterationResult.ran
                let now = clock()
                do {
                    try await job.run(
                        WorkerContext(
                            db: connection, application: application, logger: logger, now: now))
                } catch {
                    logger.report(error: error)
                    result = .failed(String(describing: error))
                }
                do {
                    try await Self.beat(job.name, at: clock(), result: result, on: sql)
                } catch {
                    logger.report(error: error)
                }
                try await Self.unlock(job, on: sql)
                return result
            }
        } catch {
            logger.report(error: error)
            return .failed(String(describing: error))
        }
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw APIError(code: .internal, message: "worker needs an SQL database")
        }
        return sql
    }

    private struct LockRow: Decodable {
        var locked: Bool
    }

    static func tryLock(_ job: WorkerJob, on sql: any SQLDatabase) async throws -> Bool {
        let row = try await sql.raw(
            """
            SELECT pg_try_advisory_lock(\(bind: WorkerJob.lockNamespace), \(bind: job.lockKey)) \
            AS locked
            """
        ).first(decoding: LockRow.self)
        return row?.locked ?? false
    }

    static func unlock(_ job: WorkerJob, on sql: any SQLDatabase) async throws {
        try await sql.raw(
            """
            SELECT pg_advisory_unlock(\(bind: WorkerJob.lockNamespace), \(bind: job.lockKey)) \
            AS unlocked
            """
        ).run()
    }

    static func beat(
        _ loop: String, at date: Date, result: IterationResult, on sql: any SQLDatabase
    )
        async throws
    {
        let error: String?
        if case .failed(let message) = result {
            error = String(message.prefix(2_000))
        } else {
            error = nil
        }
        try await sql.raw(
            """
            INSERT INTO worker_heartbeat (id, loop, last_beat_at, last_error, last_error_at)
            VALUES (\(bind: UUID()), \(bind: loop), \(bind: date), \(bind: error), \
            \(bind: error == nil ? nil : date))
            ON CONFLICT (loop) DO UPDATE SET
                last_beat_at = EXCLUDED.last_beat_at,
                last_error = COALESCE(EXCLUDED.last_error, worker_heartbeat.last_error),
                last_error_at = COALESCE(EXCLUDED.last_error_at, worker_heartbeat.last_error_at)
            """
        ).run()
    }
}

extension WorkerJob {
    /// Always registered: proves the worker process is alive even before feature loops exist.
    static let processHeartbeat = WorkerJob(
        name: "worker", lockKey: 1, interval: .seconds(30), run: { _ in })
}
