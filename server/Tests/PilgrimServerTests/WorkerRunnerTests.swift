import Fluent
import Foundation
import NIOConcurrencyHelpers
import PilgrimAPI
import SQLKit
import XCTVapor
import XCTest

@testable import PilgrimServerCore

final class WorkerRunnerTests: DatabaseTestCase {
    func testIterationRunsTheJobAndBeats() async throws {
        let runs = NIOLockedValueBox(0)
        let job = WorkerJob(name: "test-loop", lockKey: 900, interval: .seconds(60)) { context in
            runs.withLockedValue { $0 += 1 }
            // The job gets a working connection.
            _ = try await User.query(on: context.db).count()
        }
        let fixedNow = Date(timeIntervalSince1970: 1_900_000_000)
        let runner = WorkerRunner(application: app, clock: { fixedNow })

        let result = await runner.runOnce(job)
        XCTAssertEqual(result, .ran)
        XCTAssertEqual(runs.withLockedValue { $0 }, 1)
        let beat = try await unwrapAsync(
            try await WorkerHeartbeat.query(on: db).filter(\.$loop == "test-loop").first())
        XCTAssertEqual(beat.lastBeatAt, fixedNow)
        XCTAssertNil(beat.lastError)

        // Running again updates the same row.
        _ = await runner.runOnce(job)
        let beatCount = try await WorkerHeartbeat.query(on: db).count()
        XCTAssertEqual(beatCount, 1)
        XCTAssertEqual(runs.withLockedValue { $0 }, 2)
    }

    func testFailureIsRecordedAndStillBeats() async throws {
        struct Broken: Error {}
        let job = WorkerJob(name: "broken", lockKey: 901, interval: .seconds(60)) { _ in
            throw Broken()
        }
        let result = await WorkerRunner(application: app).runOnce(job)
        guard case .failed = result else { return XCTFail("expected failure, got \(result)") }
        let beat = try await unwrapAsync(
            try await WorkerHeartbeat.query(on: db).filter(\.$loop == "broken").first())
        XCTAssertNotNil(beat.lastError)
        XCTAssertNotNil(beat.lastErrorAt)
    }

    func testLockedJobIsSkipped() async throws {
        let ran = NIOLockedValueBox(false)
        let job = WorkerJob(name: "contended", lockKey: 902, interval: .seconds(60)) { _ in
            ran.withLockedValue { $0 = true }
        }
        // Another session (a second worker process) holds the lock while we try.
        let app = self.app!
        let result = try await app.db.withConnection { other -> WorkerRunner.IterationResult in
            let sql = other as! any SQLDatabase
            try await sql.raw(
                "SELECT pg_advisory_lock(\(bind: WorkerJob.lockNamespace), \(bind: job.lockKey))"
            ).run()
            let result = await WorkerRunner(application: app).runOnce(job)
            try await sql.raw(
                "SELECT pg_advisory_unlock(\(bind: WorkerJob.lockNamespace), \(bind: job.lockKey))"
            ).run()
            return result
        }
        XCTAssertEqual(result, .skippedLocked)
        XCTAssertFalse(ran.withLockedValue { $0 })
        let beats = try await WorkerHeartbeat.query(on: db).count()
        XCTAssertEqual(beats, 0)

        // Once released, the next iteration runs.
        let after = await WorkerRunner(application: app).runOnce(job)
        XCTAssertEqual(after, .ran)
    }

    func testRunLoopsUntilCancelled() async throws {
        let runs = NIOLockedValueBox(0)
        let job = WorkerJob(name: "fast", lockKey: 903, interval: .milliseconds(50)) { _ in
            runs.withLockedValue { $0 += 1 }
        }
        let runner = WorkerRunner(application: app)
        let task = Task { await runner.run(jobs: [job]) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        await task.value
        XCTAssertGreaterThanOrEqual(runs.withLockedValue { $0 }, 2)
    }
}

final class HealthTests: DatabaseTestCase {
    func testDegradedUntilEveryLoopBeats() async throws {
        try await app.test(.GET, "api/health") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
            let health = try decode(HealthResponse.self, from: res)
            XCTAssertTrue(health.database)
            XCTAssertEqual(health.status, .degraded)
            XCTAssertFalse(health.worker.healthy)
            XCTAssertNil(health.worker.lastBeatAt)
        }

        let runner = WorkerRunner(application: app)
        for job in app.workerJobs.jobs {
            _ = await runner.runOnce(job)
        }
        try await app.test(.GET, "api/health") { res async throws in
            let health = try decode(HealthResponse.self, from: res)
            XCTAssertEqual(health.status, .ok)
            XCTAssertTrue(health.worker.healthy)
            XCTAssertNotNil(health.worker.lastBeatAt)
        }

        // A beat older than two minutes makes the worker unhealthy again.
        try await sql.raw(
            "UPDATE worker_heartbeat SET last_beat_at = now() - interval '3 minutes'"
        ).run()
        try await app.test(.GET, "api/health") { res async throws in
            let health = try decode(HealthResponse.self, from: res)
            XCTAssertEqual(health.status, .degraded)
            XCTAssertFalse(health.worker.healthy)
        }
    }
}
