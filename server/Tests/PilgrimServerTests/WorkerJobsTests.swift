import Crypto
import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// S5 loops against Postgres (skipped without `TEST_DATABASE_URL`).
class WorkerDatabaseTestCase: DatabaseTestCase {
    /// Runs the registered job `name` once with the clock fixed at `now`.
    @discardableResult
    func runJob(_ name: String, at now: Date) async throws -> WorkerRunner.IterationResult {
        let job = try XCTUnwrap(app.workerJobs.jobs.first { $0.name == name }, name)
        return await WorkerRunner(application: app, clock: { now }).runOnce(job)
    }

    @discardableResult
    func device(
        for user: User, token: String?, environment: APNSEnvironment = .production,
        bundleID: String = BundleIDs.release
    ) async throws -> Device {
        let device = Device(
            userID: try user.requireID(), installationID: UUID(), apnsToken: token,
            apnsEnvironment: environment, bundleID: bundleID, platform: .ios)
        try await device.create(on: db)
        return device
    }

    func outbox() async throws -> [PushOutboxEntry] {
        try await PushOutboxEntry.query(on: db).sort(\.$createdAt).all()
    }

    /// Puts `group` into a round of voting, as S2's leave route will.
    @discardableResult
    func openVote(
        in group: Group, round: Int = 1, candidates: [User], startedAt: Date, endsAt: Date
    ) async throws -> AdminVote {
        group.$admin.id = nil
        group.status = .voting
        try await group.update(on: db)
        let ids = try candidates.map { try $0.requireID() }
        let vote = AdminVote(
            groupID: try group.requireID(), round: round, candidateIDs: ids, eligibleIDs: ids,
            startedAt: startedAt, endsAt: endsAt)
        try await vote.create(on: db)
        return vote
    }

    func ballot(_ vote: AdminVote, from voter: User, for candidate: User) async throws {
        try await Ballot(
            voteID: try vote.requireID(), voterID: try voter.requireID(),
            candidateID: try candidate.requireID()
        ).create(on: db)
    }
}

final class PushOutboxJobTests: WorkerDatabaseTestCase {
    func testSendsToEveryDeviceWithItsTopicAndEnvironment() async throws {
        let sender = FakeAPNSSender()
        app.apnsSender = sender
        let author = try await fixtures.user("민지")
        let reader = try await fixtures.user("요한")
        let group = try await fixtures.group(admin: author, members: [reader])
        try await device(for: reader, token: "release-token")
        try await device(
            for: reader, token: "debug-token", environment: .sandbox, bundleID: BundleIDs.debug)
        try await device(for: reader, token: nil)
        let post = try await fixtures.post(by: author, in: group, kind: .prayer, body: "비밀 기도")
        try await PushOutbox.enqueue(on: db, post: post)

        let now = Date()
        let result = try await runJob("pushOutbox", at: now)
        XCTAssertEqual(result, .ran)

        let deliveries = sender.deliveries.sorted { $0.deviceToken < $1.deviceToken }
        XCTAssertEqual(deliveries.map(\.deviceToken), ["debug-token", "release-token"])
        XCTAssertEqual(deliveries.map(\.topic), [BundleIDs.debug, BundleIDs.release])
        XCTAssertEqual(deliveries.map(\.environment), [.sandbox, .production])
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertEqual(deliveries[0].collapseID, try row.requireID().pilgrimString)
        XCTAssertEqual(deliveries[0].payload.aps.alert.locArgs, ["민지"])
        XCTAssertFalse(String(describing: deliveries[0].payload).contains("비밀 기도"))
        XCTAssertNotNil(row.sentAt)
        XCTAssertEqual(row.attempts, 1)

        // A sent row is not sent again.
        _ = try await runJob("pushOutbox", at: now.addingTimeInterval(10))
        XCTAssertEqual(sender.deliveries.count, 2)
    }

    func testInvalidTokensAreClearedAndTheRowStillCountsAsSent() async throws {
        let sender = FakeAPNSSender()
        sender.answer(.invalidToken("410 Unregistered"), forToken: "gone")
        app.apnsSender = sender
        let user = try await fixtures.user()
        let dead = try await device(for: user, token: "gone")
        let alive = try await device(for: user, token: "alive")
        try await PushOutbox.enqueue(
            on: db, recipients: [try user.requireID()], payload: .dailyReport(itemCount: 2))

        try await runJob("pushOutbox", at: Date())

        let deadAfter = try await Device.find(try dead.requireID(), on: db)
        XCTAssertNil(deadAfter?.apnsToken)
        let aliveAfter = try await Device.find(try alive.requireID(), on: db)
        XCTAssertEqual(aliveAfter?.apnsToken, "alive")
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertNotNil(row.sentAt)
    }

    func testServerErrorsRetryThreeTimesThenFail() async throws {
        let sender = FakeAPNSSender()
        sender.answer(.retryLater("503 ServiceUnavailable"), forToken: "token")
        app.apnsSender = sender
        let user = try await fixtures.user()
        try await device(for: user, token: "token")
        let start = Date()
        try await PushOutbox.enqueue(
            on: db, recipients: [try user.requireID()], payload: .dailyReport(itemCount: 1),
            now: start)

        var now = start
        for (attempt, delay) in [(1, 30.0), (2, 120.0), (3, 600.0)] {
            try await runJob("pushOutbox", at: now)
            let row = try await unwrapAsync(try await outbox().first)
            XCTAssertEqual(row.attempts, attempt)
            XCTAssertNil(row.failedAt)
            XCTAssertEqual(
                row.nextAttemptAt.timeIntervalSince1970,
                now.addingTimeInterval(delay)
                    .timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(row.lastError, "503 ServiceUnavailable")
            // Not due yet: nothing is sent.
            let before = sender.deliveries.count
            try await runJob("pushOutbox", at: now.addingTimeInterval(delay - 1))
            XCTAssertEqual(sender.deliveries.count, before)
            now = now.addingTimeInterval(delay)
        }
        try await runJob("pushOutbox", at: now)
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertEqual(row.attempts, 4)
        XCTAssertNotNil(row.failedAt)
        XCTAssertNil(row.sentAt)
        XCTAssertEqual(sender.deliveries.count, 4)
    }

    func testRecipientWithoutDevicesIsMarkedSent() async throws {
        app.apnsSender = FakeAPNSSender()
        let user = try await fixtures.user()
        try await PushOutbox.enqueue(
            on: db, recipients: [try user.requireID()], payload: .dailyReport(itemCount: 1))
        try await runJob("pushOutbox", at: Date())
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertNotNil(row.sentAt)
    }

    func testWithoutAPNsDevelopmentDropsDueRows() async throws {
        let user = try await fixtures.user()
        try await device(for: user, token: "token")
        try await PushOutbox.enqueue(
            on: db, recipients: [try user.requireID()], payload: .dailyReport(itemCount: 1))
        let value1 = try await runJob("pushOutbox", at: Date())
        XCTAssertEqual(value1, .ran)
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertNotNil(row.failedAt)
        XCTAssertEqual(row.lastError, "APNs is not configured")
    }

    func testWithoutAPNsProductionKeepsRowsAndFails() async throws {
        let user = try await fixtures.user()
        try await PushOutbox.enqueue(
            on: db, recipients: [try user.requireID()], payload: .dailyReport(itemCount: 1))
        do {
            try await PushOutboxSender.run(
                on: db, sender: UnconfiguredAPNSSender(), allowedBundleIDs: BundleIDs.all,
                isProduction: true, now: Date(), logger: app.logger)
            XCTFail("expected a configuration error")
        } catch is ConfigurationError {}
        let row = try await unwrapAsync(try await outbox().first)
        XCTAssertNil(row.failedAt)
        XCTAssertNil(row.sentAt)
    }
}

final class CleanupJobTests: WorkerDatabaseTestCase {
    func testExpiryDeletesPostsWithTheirContentAndQueuesFiles() async throws {
        let author = try await fixtures.user()
        let group = try await fixtures.group(admin: author)
        let now = Date()
        let expired = try await fixtures.post(
            by: author, in: group, expiresAt: now.addingTimeInterval(-1))
        let live = try await fixtures.post(
            by: author, in: group, expiresAt: now.addingTimeInterval(60))
        let media = try await fixtures.media(uploadedBy: author, in: group, post: expired)
        try await Comment(
            postID: try expired.requireID(), authorID: try author.requireID(), body: "아멘",
            clientID: UUID()
        ).create(on: db)

        let value2 = try await runJob("expiry", at: now)
        XCTAssertEqual(value2, .ran)

        let expiredGone = try await Post.find(try expired.requireID(), on: db)
        XCTAssertNil(expiredGone)
        let liveKept = try await Post.find(try live.requireID(), on: db)
        XCTAssertNotNil(liveKept)
        let value3 = try await Comment.query(on: db).count()
        XCTAssertEqual(value3, 0)
        let value4 = try await Media.query(on: db).count()
        XCTAssertEqual(value4, 0)
        let queued = try await MediaFileDeletion.query(on: db).all().map(\.filePath)
        XCTAssertEqual(queued, [media.filePath])
    }

    func testMediaFilesAreDeletedAndUnattachedUploadsExpire() async throws {
        let user = try await fixtures.user()
        let group = try await fixtures.group(admin: user)
        let now = Date()
        let fresh = try await fixtures.media(uploadedBy: user, in: group)
        let stale = try await fixtures.media(uploadedBy: user, in: group)
        try await sql.raw(
            """
            UPDATE media SET created_at = \(bind: now.addingTimeInterval(-25 * 3_600))
            WHERE id = \(bind: try stale.requireID())
            """
        ).run()
        try await app.mediaStore.write(Data([0xFF, 0xD8, 0xFF]), to: stale.filePath)
        let value5 = await app.mediaStore.exists(stale.filePath)
        XCTAssertTrue(value5)
        // A queued file that is already gone still counts as deleted.
        try await sql.raw(
            """
            INSERT INTO media_file_deletions (id, file_path, attempts, created_at)
            VALUES (\(bind: UUID()), 'ab/missing.jpg', 0, \(bind: now))
            """
        ).run()

        let value6 = try await runJob("mediaFiles", at: now)
        XCTAssertEqual(value6, .ran)

        let staleGone = try await Media.find(try stale.requireID(), on: db)
        XCTAssertNil(staleGone)
        let freshKept = try await Media.find(try fresh.requireID(), on: db)
        XCTAssertNotNil(freshKept)
        let value7 = await app.mediaStore.exists(stale.filePath)
        XCTAssertFalse(value7)
        let value8 = try await MediaFileDeletion.query(on: db).count()
        XCTAssertEqual(value8, 0)
    }

    func testOldInvitesAreDeleted() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let now = Date()
        let old = Invite(
            groupID: try group.requireID(), code: "ABCDEFGHJKMN",
            createdByID: try admin.requireID(),
            maxUses: 5, expiresAt: now.addingTimeInterval(-8 * 86_400))
        let recent = Invite(
            groupID: try group.requireID(), code: "ABCDEFGHJKMP",
            createdByID: try admin.requireID(),
            maxUses: 5, expiresAt: now.addingTimeInterval(-6 * 86_400))
        try await old.create(on: db)
        try await recent.create(on: db)

        try await runJob("invites", at: now)

        let codes = try await Invite.query(on: db).all().map(\.code)
        XCTAssertEqual(codes, ["ABCDEFGHJKMP"])
    }

    func testRetentionRemovesOldOperationalRows() async throws {
        let user = try await fixtures.user()
        let userID = try user.requireID()
        let now = Date()
        let day: TimeInterval = 86_400
        let sentOld = PushOutboxEntry(recipientID: userID, payload: .dailyReport(itemCount: 1))
        sentOld.sentAt = now.addingTimeInterval(-8 * day)
        let sentRecent = PushOutboxEntry(recipientID: userID, payload: .dailyReport(itemCount: 1))
        sentRecent.sentAt = now.addingTimeInterval(-6 * day)
        let failedOld = PushOutboxEntry(recipientID: userID, payload: .dailyReport(itemCount: 1))
        failedOld.failedAt = now.addingTimeInterval(-31 * day)
        let pending = PushOutboxEntry(recipientID: userID, payload: .dailyReport(itemCount: 1))
        for entry in [sentOld, sentRecent, failedOld, pending] {
            try await entry.create(on: db)
        }
        let expiredToken = RefreshToken(
            userID: userID, familyID: UUID(), tokenHash: Data(repeating: 1, count: 32),
            installationID: UUID(), issuedAt: now.addingTimeInterval(-100 * day),
            expiresAt: now.addingTimeInterval(-8 * day))
        let liveToken = RefreshToken(
            userID: userID, familyID: UUID(), tokenHash: Data(repeating: 2, count: 32),
            installationID: UUID(), issuedAt: now, expiresAt: now.addingTimeInterval(90 * day))
        try await expiredToken.create(on: db)
        try await liveToken.create(on: db)

        try await runJob("retention", at: now)

        let remaining = Set(try await outbox().map { try $0.requireID() })
        XCTAssertEqual(remaining, [try sentRecent.requireID(), try pending.requireID()])
        let tokens = try await RefreshToken.query(on: db).all().map { try $0.requireID() }
        XCTAssertEqual(tokens, [try liveToken.requireID()])
    }
}

final class VoteJobTests: WorkerDatabaseTestCase {
    func testMajorityElectsAndNotifiesEveryMember() async throws {
        let a = try await fixtures.user("가")
        let b = try await fixtures.user("나")
        let c = try await fixtures.user("다")
        let group = try await fixtures.group(admin: a, members: [b, c])
        let start = Date()
        let vote = try await openVote(
            in: group, candidates: [a, b, c], startedAt: start, endsAt: start + 3 * 86_400)
        try await ballot(vote, from: a, for: b)
        try await ballot(vote, from: b, for: b)
        try await ballot(vote, from: c, for: a)

        // Not over yet.
        try await runJob("votes", at: start + 3 * 86_400 - 1)
        let stillOpen = try await AdminVote.find(try vote.requireID(), on: db)
        XCTAssertEqual(stillOpen?.status, .open)

        let value9 = try await runJob("votes", at: start + 3 * 86_400)
        XCTAssertEqual(value9, .ran)
        let closed = try await unwrapAsync(try await AdminVote.find(try vote.requireID(), on: db))
        XCTAssertEqual(closed.status, .closed)
        XCTAssertEqual(closed.outcome, .elected)
        XCTAssertEqual(closed.$electedUser.id, try b.requireID())
        let after = try await unwrapAsync(try await Group.find(try group.requireID(), on: db))
        XCTAssertEqual(after.status, .active)
        XCTAssertEqual(after.$admin.id, try b.requireID())

        let notices = try await outbox()
        XCTAssertEqual(notices.count, 3)
        XCTAssertTrue(notices.allSatisfy { $0.kind == .voteDecided })
        XCTAssertEqual(notices.first?.payload.aps.alert.locArgs, ["나"])
    }

    func testTieGoesToRunoffAndARunoffTieIsRandom() async throws {
        let a = try await fixtures.user("가")
        let b = try await fixtures.user("나")
        let c = try await fixtures.user("다")
        let group = try await fixtures.group(admin: a, members: [b, c])
        let start = Date()
        let vote = try await openVote(
            in: group, candidates: [a, b, c], startedAt: start, endsAt: start + 3 * 86_400)
        try await ballot(vote, from: a, for: a)
        try await ballot(vote, from: b, for: b)

        let roundOneEnd = start + 3 * 86_400
        try await runJob("votes", at: roundOneEnd)
        let first = try await unwrapAsync(try await AdminVote.find(try vote.requireID(), on: db))
        XCTAssertEqual(first.outcome, .runoff)
        let runoff = try await unwrapAsync(
            try await AdminVote.query(on: db).filter(\.$status == .open).first())
        XCTAssertEqual(runoff.round, 2)
        XCTAssertEqual(Set(runoff.candidateIDs), [try a.requireID(), try b.requireID()])
        XCTAssertEqual(runoff.eligibleIDs.count, 3)
        XCTAssertEqual(
            runoff.endsAt.timeIntervalSince1970, (roundOneEnd + 86_400).timeIntervalSince1970,
            accuracy: 0.001)
        let value10 = try await outbox().filter { $0.kind == .voteRunoff }.count
        XCTAssertEqual(value10, 3)

        // Round 2: one vote each again → random among the runoff candidates.
        try await ballot(runoff, from: a, for: a)
        try await ballot(runoff, from: c, for: b)
        try await VoteSweep.run(
            on: db, now: roundOneEnd + 86_400, dayLength: 86_400, random: fixedRandom([0]),
            logger: app.logger)
        let decided = try await unwrapAsync(
            try await AdminVote.find(try runoff.requireID(), on: db))
        XCTAssertEqual(decided.outcome, .random)
        let winner = try XCTUnwrap(decided.$electedUser.id)
        XCTAssertTrue([try a.requireID(), try b.requireID()].contains(winner))
        let after = try await unwrapAsync(try await Group.find(try group.requireID(), on: db))
        XCTAssertEqual(after.$admin.id, winner)
        XCTAssertEqual(after.status, .active)
    }

    func testNoVotesSchedulesDeletionAndTheGraceDeletesTheGroup() async throws {
        let a = try await fixtures.user()
        let b = try await fixtures.user()
        let group = try await fixtures.group(admin: a, members: [b])
        let author = try await fixtures.user()
        try await fixtures.join(author, group)
        let post = try await fixtures.post(by: author, in: group)
        _ = try await fixtures.media(uploadedBy: author, in: group, post: post)
        let start = Date()
        let vote = try await openVote(
            in: group, candidates: [a, b, author], startedAt: start, endsAt: start + 3 * 86_400)

        let end = start + 3 * 86_400
        try await runJob("votes", at: end)
        let closed = try await unwrapAsync(try await AdminVote.find(try vote.requireID(), on: db))
        XCTAssertEqual(closed.outcome, .noVotes)
        let pending = try await unwrapAsync(try await Group.find(try group.requireID(), on: db))
        XCTAssertEqual(pending.status, .pendingDeletion)
        XCTAssertEqual(pending.deletionReason, .noVotes)
        let deleteAt = try XCTUnwrap(pending.deleteAt)
        XCTAssertEqual(
            deleteAt.timeIntervalSince1970, (end + 7 * 86_400).timeIntervalSince1970,
            accuracy: 0.001)
        let value11 = try await outbox().filter { $0.kind == .groupDeletionScheduled }.count
        XCTAssertEqual(value11, 3)

        try await runJob("votes", at: deleteAt - 1)
        let notYet = try await Group.find(try group.requireID(), on: db)
        XCTAssertNotNil(notYet)

        try await runJob("votes", at: deleteAt)
        let gone = try await Group.find(try group.requireID(), on: db)
        XCTAssertNil(gone)
        let value12 = try await Post.query(on: db).count()
        XCTAssertEqual(value12, 0)
        let value13 = try await MediaFileDeletion.query(on: db).count()
        XCTAssertEqual(value13, 1)
    }

    func testRestartWhenEveryCandidateLeft() async throws {
        let a = try await fixtures.user()
        let b = try await fixtures.user()
        let c = try await fixtures.user()
        let d = try await fixtures.user()
        let group = try await fixtures.group(admin: a, members: [b])
        let start = Date()
        let vote = try await openVote(
            in: group, round: 2, candidates: [a, b], startedAt: start, endsAt: start + 86_400)
        // Both candidates leave; two newcomers join.
        try await Membership.query(on: db).filter(\.$group.$id == (try group.requireID())).delete()
        try await fixtures.join(c, group)
        try await fixtures.join(d, group)

        try await runJob("votes", at: start + 86_400)
        let closed = try await unwrapAsync(try await AdminVote.find(try vote.requireID(), on: db))
        XCTAssertEqual(closed.outcome, .restarted)
        let restarted = try await unwrapAsync(
            try await AdminVote.query(on: db).filter(\.$status == .open).first())
        XCTAssertEqual(restarted.round, 1)
        XCTAssertEqual(Set(restarted.candidateIDs), [try c.requireID(), try d.requireID()])
        let value14 = try await outbox().filter { $0.kind == .voteStarted }.count
        XCTAssertEqual(value14, 2)
    }

    func testVoteWithNoMembersLeftDeletesTheGroup() async throws {
        let a = try await fixtures.user()
        let b = try await fixtures.user()
        let group = try await fixtures.group(admin: a, members: [b])
        let start = Date()
        try await openVote(in: group, candidates: [a, b], startedAt: start, endsAt: start + 60)
        try await Membership.query(on: db).filter(\.$group.$id == (try group.requireID())).delete()

        try await runJob("votes", at: start + 60)
        let gone = try await Group.find(try group.requireID(), on: db)
        XCTAssertNil(gone)
        let value15 = try await AdminVote.query(on: db).count()
        XCTAssertEqual(value15, 0)
    }
}

final class AppleRevocationJobTests: WorkerDatabaseTestCase {
    var cipher: AppleTokenCipher { app.authServices.appleTokenCipher }

    func testRevokesWithTheAuthServicesAndBacksOffOnFailure() async throws {
        let revoker = FakeAppleRevoker()
        app.authServices.appleAuthorization = revoker
        let now = Date()
        let ok = AppleTokenRevocation(
            clientID: BundleIDs.release, ciphertext: try cipher.encrypt("token-ok"),
            nextAttemptAt: now)
        try await ok.create(on: db)

        let result = try await runJob("appleRevocation", at: now)
        XCTAssertEqual(result, .ran)
        XCTAssertEqual(revoker.calls.map(\.token), ["token-ok"])
        XCTAssertEqual(revoker.calls.map(\.clientID), [BundleIDs.release])
        let done = try await unwrapAsync(
            try await AppleTokenRevocation.find(try ok.requireID(), on: db))
        XCTAssertNotNil(done.completedAt)
        XCTAssertEqual(done.attempts, 1)

        revoker.fail(status: 400)
        let failing = AppleTokenRevocation(
            clientID: BundleIDs.debug, ciphertext: try cipher.encrypt("token-bad"),
            nextAttemptAt: now)
        try await failing.create(on: db)
        try await AppleRevocationSweep.run(
            on: db, authorization: revoker, cipher: cipher, now: now, logger: app.logger)
        let retried = try await unwrapAsync(
            try await AppleTokenRevocation.find(try failing.requireID(), on: db))
        XCTAssertEqual(retried.attempts, 1)
        XCTAssertNil(retried.completedAt)
        XCTAssertEqual(retried.lastError, "Apple /auth/revoke answered HTTP 400")
        XCTAssertEqual(
            retried.nextAttemptAt.timeIntervalSince1970,
            now.addingTimeInterval(300).timeIntervalSince1970, accuracy: 0.001)
        // The completed row is not sent again.
        XCTAssertEqual(revoker.calls.count, 2)

        // Once Apple answers, the retry completes.
        revoker.fail(status: nil)
        try await AppleRevocationSweep.run(
            on: db, authorization: revoker, cipher: cipher, now: now.addingTimeInterval(300),
            logger: app.logger)
        let completed = try await unwrapAsync(
            try await AppleTokenRevocation.find(try failing.requireID(), on: db))
        XCTAssertNotNil(completed.completedAt)
        XCTAssertNil(completed.lastError)
    }

    func testGivesUpAfterTenAttemptsAndKeepsTheError() async throws {
        let revoker = FakeAppleRevoker()
        revoker.fail(status: 500)
        let now = Date()
        let row = AppleTokenRevocation(
            clientID: BundleIDs.release, ciphertext: try cipher.encrypt("t"), nextAttemptAt: now)
        row.attempts = 9
        try await row.create(on: db)

        try await AppleRevocationSweep.run(
            on: db, authorization: revoker, cipher: cipher, now: now, logger: app.logger)
        try await AppleRevocationSweep.run(
            on: db, authorization: revoker, cipher: cipher,
            now: now.addingTimeInterval(86_400 * 30), logger: app.logger)
        XCTAssertEqual(revoker.calls.count, 1)
        let after = try await unwrapAsync(
            try await AppleTokenRevocation.find(try row.requireID(), on: db))
        XCTAssertEqual(after.attempts, 10)
        XCTAssertEqual(after.lastError, "Apple /auth/revoke answered HTTP 500")
        XCTAssertNil(after.completedAt)
    }

    func testUndecryptableRowIsGivenUpWithoutCallingApple() async throws {
        let revoker = FakeAppleRevoker()
        let other = AppleTokenCipher.ephemeral()
        let row = AppleTokenRevocation(
            clientID: BundleIDs.release, ciphertext: try other.encrypt("t"), nextAttemptAt: Date())
        try await row.create(on: db)

        try await AppleRevocationSweep.run(
            on: db, authorization: revoker, cipher: cipher, now: Date(), logger: app.logger)
        XCTAssertTrue(revoker.calls.isEmpty)
        let after = try await unwrapAsync(
            try await AppleTokenRevocation.find(try row.requireID(), on: db))
        XCTAssertEqual(after.attempts, AppleRevocationSweep.maximumAttempts)
        XCTAssertEqual(after.lastError, "cannot decrypt")
    }
}

/// 1.5.6: the whole worker cycle with a shortened day (`TIME_SCALE_DAY_SECONDS`).
final class ScaledWorkerFlowTests: WorkerDatabaseTestCase {
    static let day: TimeInterval = 60

    override func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot, dayLength: Self.day)
    }

    func testPostVoteAndCleanupCycleWithAOneMinuteDay() async throws {
        let sender = FakeAPNSSender()
        app.apnsSender = sender
        let admin = try await fixtures.user("관리자")
        let mina = try await fixtures.user("민아")
        let joon = try await fixtures.user("준")
        let group = try await fixtures.group(admin: admin, members: [mina, joon])
        for user in [admin, mina, joon] {
            try await device(for: user, token: "token-\(try user.requireID().pilgrimString)")
        }

        // A testimony expiring after 7 scaled days, with a photo on disk.
        let start = Date()
        let policy = PostExpiryPolicy(dayLength: Self.day)
        let expiresAt = try policy.expiresAt(
            kind: .testimony, createdAt: start, deadline: nil, visibleDays: nil,
            timeZone: TimeZone(identifier: "Asia/Seoul")!)
        XCTAssertEqual(expiresAt.timeIntervalSince(start), 7 * Self.day, accuracy: 0.001)
        let post = try await fixtures.post(by: mina, in: group, expiresAt: expiresAt)
        let photo = try await fixtures.media(uploadedBy: mina, in: group, post: post)
        try await app.mediaStore.write(Data([0xFF, 0xD8, 0xFF]), to: photo.filePath)
        try await PushOutbox.enqueue(on: db, post: post, now: start)

        try await runJob("pushOutbox", at: start)
        XCTAssertEqual(sender.deliveries.count, 2) // everyone but the author

        // The admin leaves: round 1 among the other two (S2 opens it; here by hand).
        try await Membership.query(on: db)
            .filter(\.$group.$id == (try group.requireID()))
            .filter(\.$user.$id == (try admin.requireID()))
            .delete()
        let roundOne = try await openVote(
            in: group, candidates: [mina, joon], startedAt: start,
            endsAt: start + AdminVoteRules.roundLength(1, dayLength: Self.day))
        try await ballot(roundOne, from: mina, for: mina)
        try await ballot(roundOne, from: joon, for: joon)

        var now = start + 3 * Self.day
        try await runJob("votes", at: now)
        try await runJob("pushOutbox", at: now)
        XCTAssertEqual(sender.deliveries.filter { $0.payload.pilgrim.kind == .voteRunoff }.count, 2)

        let runoff = try await unwrapAsync(
            try await AdminVote.query(on: db).filter(\.$status == .open).first())
        try await ballot(runoff, from: mina, for: joon)
        try await ballot(runoff, from: joon, for: joon)
        now = now + Self.day
        try await runJob("votes", at: now)
        try await runJob("pushOutbox", at: now)
        let decided = try await unwrapAsync(try await Group.find(try group.requireID(), on: db))
        XCTAssertEqual(decided.$admin.id, try joon.requireID())
        XCTAssertEqual(decided.status, .active)
        let decidedPushes = sender.deliveries.filter { $0.payload.pilgrim.kind == .voteDecided }
        XCTAssertEqual(decidedPushes.count, 2)
        XCTAssertEqual(decidedPushes.first?.payload.aps.alert.locArgs, ["준"])

        // Day 7: the post expires, the photo file is removed.
        now = start + 7 * Self.day
        try await runJob("expiry", at: now)
        try await runJob("mediaFiles", at: now)
        let expired = try await Post.find(try post.requireID(), on: db)
        XCTAssertNil(expired)
        let value18 = await app.mediaStore.exists(photo.filePath)
        XCTAssertFalse(value18)

        // Retention is real time: a week later the sent pushes are gone.
        try await runJob("retention", at: now + 8 * 86_400)
        let value19 = try await outbox().count
        XCTAssertEqual(value19, 0)

        // Every loop beat.
        let beats = Set(try await WorkerHeartbeat.query(on: db).all().map(\.loop))
        XCTAssertTrue(
            beats.isSuperset(of: ["pushOutbox", "votes", "expiry", "mediaFiles", "retention"]))
    }
}
