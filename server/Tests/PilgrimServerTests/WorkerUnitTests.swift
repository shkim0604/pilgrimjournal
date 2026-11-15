import Crypto
import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

/// S5 rules that need no database.
final class PushRulesTests: XCTestCase {
    func testClassifyAPNsResponses() {
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 410, reason: "Unregistered"),
            .invalidToken("410 Unregistered"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 400, reason: "BadDeviceToken"),
            .invalidToken("400 BadDeviceToken"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 400, reason: "DeviceTokenNotForTopic"),
            .invalidToken("400 DeviceTokenNotForTopic"))
        XCTAssertEqual(APNSDeliveryResult.classify(status: 410, reason: nil), .invalidToken("410"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 503, reason: "ServiceUnavailable"),
            .retryLater("503 ServiceUnavailable"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 429, reason: "TooManyRequests"),
            .retryLater("429 TooManyRequests"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 403, reason: "ExpiredProviderToken"),
            .retryLater("403 ExpiredProviderToken"))
        XCTAssertEqual(
            APNSDeliveryResult.classify(status: 413, reason: "PayloadTooLarge"),
            .rejected("413 PayloadTooLarge"))
    }

    func testRetryScheduleIsThirtySecondsTwoMinutesTenMinutesThenGiveUp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PushRetryPolicy.nextAttempt(afterFailedAttempts: 1, now: now), now + 30)
        XCTAssertEqual(PushRetryPolicy.nextAttempt(afterFailedAttempts: 2, now: now), now + 120)
        XCTAssertEqual(PushRetryPolicy.nextAttempt(afterFailedAttempts: 3, now: now), now + 600)
        XCTAssertNil(PushRetryPolicy.nextAttempt(afterFailedAttempts: 4, now: now))
    }

    func testRowDecision() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        typealias D = PushOutboxSender.Decision
        XCTAssertEqual(PushOutboxSender.decide(results: [], attempts: 0, now: now), D.sent)
        XCTAssertEqual(
            PushOutboxSender.decide(
                results: [.delivered, .rejected("413")], attempts: 0, now: now), D.sent)
        XCTAssertEqual(
            PushOutboxSender.decide(results: [.invalidToken("410")], attempts: 0, now: now), D.sent)
        XCTAssertEqual(
            PushOutboxSender.decide(
                results: [.rejected("413 PayloadTooLarge")], attempts: 0, now: now),
            D.failed(attempts: 1, error: "413 PayloadTooLarge"))
        XCTAssertEqual(
            PushOutboxSender.decide(
                results: [.delivered, .retryLater("503")], attempts: 0, now: now),
            D.retry(attempts: 1, next: now + 30, error: "503"))
        XCTAssertEqual(
            PushOutboxSender.decide(results: [.retryLater("503")], attempts: 3, now: now),
            D.failed(attempts: 4, error: "503"))
    }

    func testMessageBodyIsExactlyThePayload() throws {
        let groupID = UUID()
        let postID = UUID()
        let payload = PushPayload.newPost(
            groupID: groupID, postID: postID, kind: .prayer, groupName: "수요 기도모임",
            authorName: "민지")
        let data = try PilgrimJSON.encoder.encode(PilgrimAPNSMessage(payload: payload))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["aps", "pilgrim"])
        let aps = try XCTUnwrap(json["aps"] as? [String: Any])
        XCTAssertEqual(aps["sound"] as? String, "default")
        XCTAssertEqual(aps["thread-id"] as? String, "group-\(groupID.uuidString.lowercased())")
        XCTAssertNil(aps["badge"])
        let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
        XCTAssertEqual(alert["title-loc-key"] as? String, PushLocKey.groupPushTitle)
        XCTAssertEqual(alert["title-loc-args"] as? [String], ["수요 기도모임"])
        XCTAssertEqual(alert["loc-key"] as? String, PushLocKey.newPostPrayer)
        XCTAssertEqual(alert["loc-args"] as? [String], ["민지"])
        XCTAssertEqual(Set(alert.keys), ["title-loc-key", "title-loc-args", "loc-key", "loc-args"])
        let pilgrim = try XCTUnwrap(json["pilgrim"] as? [String: Any])
        XCTAssertEqual(pilgrim["kind"] as? String, "newPost")
        XCTAssertEqual(pilgrim["groupId"] as? String, groupID.uuidString.lowercased())
        XCTAssertEqual(pilgrim["postId"] as? String, postID.uuidString.lowercased())
        XCTAssertEqual(pilgrim["v"] as? Int, 1)
    }

    func testSendAllKeepsOrderAndSendsEverything() async {
        let sender = FakeAPNSSender()
        sender.answer(.invalidToken("410"), forToken: "t3")
        let deliveries = (0..<20).map { index in
            APNSDelivery(
                deviceToken: "t\(index)", topic: BundleIDs.release, environment: .production,
                payload: .dailyReport(itemCount: index), collapseID: nil)
        }
        let results = await PushOutboxSender.sendAll(deliveries, with: sender)
        XCTAssertEqual(results.count, 20)
        XCTAssertEqual(results[3], .invalidToken("410"))
        XCTAssertEqual(results.filter { $0 == .delivered }.count, 19)
        XCTAssertEqual(
            Set(sender.deliveries.map(\.deviceToken)), Set(deliveries.map(\.deviceToken)))
    }

    func testUnconfiguredSenderIsTheDefault() async throws {
        let sender = UnconfiguredAPNSSender()
        XCTAssertFalse(sender.isConfigured)
    }

    func testPEMSettingAcceptsInlineTextWithEscapedNewlinesAndFiles() throws {
        let key = P256.Signing.PrivateKey()
        let pem = key.pemRepresentation
        let oneLine = pem.replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertEqual(
            try PEMSetting.pem(from: oneLine), pem.trimmingCharacters(in: .whitespacesAndNewlines))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("apns-\(UUID().uuidString).p8")
        try pem.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try PEMSetting.pem(from: file.path), pem)
        XCTAssertThrowsError(try PEMSetting.pem(from: "/nonexistent/key.p8"))
    }
}

final class AppleRevocationRulesTests: XCTestCase {
    func testBackoffDoublesFromFiveMinutesAndStopsAtTenAttempts() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            AppleRevocationSweep.nextAttempt(afterFailedAttempts: 1, now: now), now + 300)
        XCTAssertEqual(
            AppleRevocationSweep.nextAttempt(afterFailedAttempts: 2, now: now), now + 600)
        XCTAssertEqual(
            AppleRevocationSweep.nextAttempt(afterFailedAttempts: 4, now: now), now + 2_400)
        XCTAssertEqual(
            AppleRevocationSweep.nextAttempt(afterFailedAttempts: 9, now: now), now + 76_800)
        XCTAssertNil(AppleRevocationSweep.nextAttempt(afterFailedAttempts: 10, now: now))
    }
}

final class WorkerScheduleTests: XCTestCase {
    func testPeriodicJobTicksAtMostEveryMinuteButRunsOncePerPeriod() {
        let job = WorkerJob.periodic(name: "hourly", lockKey: 999, period: .seconds(3_600)) { _ in }
        XCTAssertEqual(job.interval, .seconds(60))
        let short = WorkerJob.periodic(name: "fast", lockKey: 998, period: .seconds(5)) { _ in }
        XCTAssertEqual(short.interval, .seconds(5))

        let gate = PeriodGate(period: 3_600)
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(gate.isDue(at: start))
        gate.markRan(at: start)
        XCTAssertFalse(gate.isDue(at: start + 60))
        XCTAssertFalse(gate.isDue(at: start + 3_599))
        XCTAssertTrue(gate.isDue(at: start + 3_600))
        // A clock that jumped backwards runs again rather than waiting an hour.
        XCTAssertTrue(gate.isDue(at: start - 1))
    }

    func testLockKeysAreUnique() {
        let keys: [Int32] = [
            WorkerLockKey.processHeartbeat, WorkerLockKey.pushOutbox, WorkerLockKey.expiry,
            WorkerLockKey.mediaFiles, WorkerLockKey.votes, WorkerLockKey.appleRevocation,
            WorkerLockKey.invites, WorkerLockKey.retention, WorkerLockKey.dailyReport,
            WorkerLockKey.subscriptions,
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}

/// Registration only: builds the app without touching Postgres.
final class WorkerRegistrationTests: ServerTestCase {
    func testEveryS5LoopIsRegisteredWithItsInterval() throws {
        let jobs = Dictionary(uniqueKeysWithValues: app.workerJobs.jobs.map { ($0.name, $0) })
        for name in [
            "worker", "pushOutbox", "expiry", "mediaFiles", "votes", "appleRevocation", "invites",
            "retention",
        ] {
            XCTAssertNotNil(jobs[name], name)
        }
        XCTAssertEqual(jobs["pushOutbox"]?.interval, .seconds(5))
        XCTAssertEqual(jobs["expiry"]?.interval, .seconds(60))
        XCTAssertEqual(jobs["votes"]?.interval, .seconds(60))
        XCTAssertEqual(jobs["mediaFiles"]?.interval, .seconds(60))
        // Longer periods still beat every minute for /api/health.
        XCTAssertEqual(jobs["appleRevocation"]?.interval, .seconds(60))
        XCTAssertEqual(jobs["retention"]?.interval, .seconds(60))
        XCTAssertFalse(app.apnsSender.isConfigured)
    }
}
