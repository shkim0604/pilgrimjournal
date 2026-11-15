import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Daily Report aggregation, the `dailyReport` loop and `GET /me/daily-report` against Postgres
/// (skipped without `TEST_DATABASE_URL`).
class DailyReportDatabaseTestCase: DatabaseTestCase {
    /// Whole seconds, so values survive the round trip through `timestamptz`.
    let drNow = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    let drUTC = TimeZone(identifier: "UTC")!

    var drWindow: DateInterval { DateInterval(start: drNow - 86_400, end: drNow) }

    func drReport(for user: User, now: Date? = nil) async throws -> DailyReportResponse {
        try await DailyReportBuilder(db: db, config: app.pilgrimConfig).report(
            for: try user.requireID(), date: LocalDate(drNow, in: drUTC), window: drWindow,
            now: now ?? drNow)
    }

    /// Sets `created_at` of a row.
    func drBackdate(_ table: String, _ id: UUID, to date: Date) async throws {
        try await sql.raw(
            "UPDATE \(ident: table) SET created_at = \(bind: date) WHERE id = \(bind: id)"
        ).run()
    }

    /// A post created `hoursAgo` hours before `drNow`.
    @discardableResult
    func drPost(
        by author: User, in group: Group, hoursAgo: Double = 1, kind: PostKind = .testimony,
        body: String = "본문", expiresIn: TimeInterval = 7 * 86_400
    ) async throws -> Post {
        let post = try await fixtures.post(
            by: author, in: group, kind: kind, body: body, expiresAt: drNow + expiresIn)
        try await drBackdate(Post.schema, try post.requireID(), to: drNow - hoursAgo * 3_600)
        return post
    }

    @discardableResult
    func drComment(on post: Post, by author: User, hoursAgo: Double = 1) async throws -> Comment {
        let comment = Comment(
            postID: try post.requireID(), authorID: try author.requireID(), body: "아멘",
            clientID: UUID())
        try await comment.create(on: db)
        try await drBackdate(Comment.schema, try comment.requireID(), to: drNow - hoursAgo * 3_600)
        return comment
    }

    func drReact(to post: Post, by user: User, emoji: String = "🙏", hoursAgo: Double = 1)
        async throws
    {
        let reaction = Reaction(
            postID: try post.requireID(), userID: try user.requireID(), key: .emoji(emoji))
        try await reaction.create(on: db)
        try await drBackdate(
            Reaction.schema, try reaction.requireID(), to: drNow - hoursAgo * 3_600)
    }

    func drExtend(_ post: Post, by user: User, hoursAgo: Double = 1) async throws {
        let extensionRow = PostExtension(
            postID: try post.requireID(), userID: try user.requireID(), clientID: UUID(),
            previousExpiresAt: post.expiresAt, newExpiresAt: post.expiresAt + 7 * 86_400)
        try await extensionRow.create(on: db)
        try await drBackdate(
            PostExtension.schema, try extensionRow.requireID(), to: drNow - hoursAgo * 3_600)
    }

    func drSetGroupReport(_ enabled: Bool, for user: User, in group: Group) async throws {
        try await sql.raw(
            """
            UPDATE memberships SET daily_report_enabled = \(bind: enabled)
            WHERE user_id = \(bind: try user.requireID()) AND group_id = \(bind: try group.requireID())
            """
        ).run()
    }

    /// Makes `user`'s report due right now: UTC, report time = the current UTC minute.
    func drMakeDue(_ user: User) async throws {
        let seconds = Int(drNow.timeIntervalSince1970) % 86_400
        user.timeZone = "UTC"
        user.dailyReportMinute = seconds / 60
        try await user.update(on: db)
    }

    func drLogs() async throws -> [DailyReportLogEntry] {
        try await DailyReportLogEntry.query(on: db).all()
    }

    func drOutbox() async throws -> [PushOutboxEntry] {
        try await PushOutboxEntry.query(on: db).all()
    }
}

final class DailyReportBuilderTests: DailyReportDatabaseTestCase {
    func testCollectsEverySection() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let other = try await fixtures.user("요한")
        let group = try await fixtures.group("수요 기도모임", admin: me, members: [friend, other])

        let fresh = try await drPost(by: friend, in: group, body: "새 글")
        let mine = try await drPost(by: me, in: group, hoursAgo: 48, body: "내 글")
        try await drComment(on: mine, by: friend)
        try await drComment(on: mine, by: other, hoursAgo: 2)
        try await drComment(on: mine, by: me) // my own comment does not count
        try await drReact(to: mine, by: friend)
        try await drReact(to: mine, by: other, emoji: "❤️")
        try await drReact(to: mine, by: me)
        let book = try await drPost(by: other, in: group, hoursAgo: 72, kind: .bookReport)
        try await drComment(on: book, by: me, hoursAgo: 60)
        try await drExtend(book, by: friend)
        let ending = try await drPost(
            by: other, in: group, hoursAgo: 100, body: "곧 끝남", expiresIn: 3_600)

        let report = try await drReport(for: me)
        XCTAssertEqual(report.windowStart, drWindow.start)
        XCTAssertEqual(report.windowEnd, drWindow.end)
        let section = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(section.groupName, "수요 기도모임")
        XCTAssertEqual(section.newPosts.map(\.postId), [try fresh.requireID()])
        XCTAssertEqual(section.newPosts.first?.title, "새 글")
        XCTAssertEqual(section.newPosts.first?.author.displayName, "민지")
        XCTAssertEqual(section.commentsOnMyPosts.map(\.postId), [try mine.requireID()])
        XCTAssertEqual(section.commentsOnMyPosts.first?.count, 2)
        XCTAssertEqual(section.reactionsOnMyPosts.first?.count, 2)
        XCTAssertEqual(section.extendedPosts.map(\.postId), [try book.requireID()])
        XCTAssertEqual(section.extendedPosts.first?.count, 1)
        XCTAssertEqual(section.expiringSoon.map(\.postId), [try ending.requireID()])
        XCTAssertEqual(report.totalCount, 5)
    }

    func testOutsideTheWindowIsLeftOut() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(admin: me, members: [friend])
        try await drPost(by: friend, in: group, hoursAgo: 25)
        let mine = try await drPost(by: me, in: group, hoursAgo: 30)
        try await drComment(on: mine, by: friend, hoursAgo: 24.5)
        try await drReact(to: mine, by: friend, hoursAgo: 26)

        let report = try await drReport(for: me)
        XCTAssertEqual(report.totalCount, 0)
        XCTAssertEqual(report.groups, [])
    }

    func testHidesAndBlocksAreApplied() async throws {
        let me = try await fixtures.user("나")
        let blocked = try await fixtures.user("차단")
        let blocker = try await fixtures.user("나를 차단")
        let hiddenPerson = try await fixtures.user("숨김")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(
            admin: me, members: [blocked, blocker, hiddenPerson, friend])
        try await fixtures.block(me, blocked)
        try await fixtures.block(blocker, me)
        try await fixtures.hide(user: hiddenPerson, by: me)

        try await drPost(by: blocked, in: group)
        try await drPost(by: blocker, in: group)
        try await drPost(by: hiddenPerson, in: group)
        let hiddenPost = try await drPost(by: friend, in: group, body: "숨긴 글")
        try await fixtures.hide(post: hiddenPost, by: me)
        let visible = try await drPost(by: friend, in: group, body: "보이는 글")

        let mine = try await drPost(by: me, in: group, hoursAgo: 48)
        for person in [blocked, blocker, hiddenPerson] {
            try await drComment(on: mine, by: person)
            try await drReact(to: mine, by: person)
        }

        let report = try await drReport(for: me)
        let section = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(section.newPosts.map(\.postId), [try visible.requireID()])
        XCTAssertEqual(section.commentsOnMyPosts, [])
        XCTAssertEqual(section.reactionsOnMyPosts, [])
        XCTAssertEqual(report.totalCount, 1)
    }

    func testGroupWithReportTurnedOffIsLeftOut() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let quiet = try await fixtures.group("조용한 모임", admin: friend, members: [me])
        let loud = try await fixtures.group("활발한 모임", admin: friend, members: [me])
        try await drPost(by: friend, in: quiet)
        try await drPost(by: friend, in: loud)
        try await drSetGroupReport(false, for: me, in: quiet)

        let report = try await drReport(for: me)
        XCTAssertEqual(report.groups.map(\.groupName), ["활발한 모임"])
        XCTAssertEqual(report.totalCount, 1)
    }

    func testExtensionsOnlyForPostsIWroteOrCommentedOnAndNotMyOwn() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(admin: me, members: [friend])
        let untouched = try await drPost(by: friend, in: group, hoursAgo: 48, kind: .bookReport)
        try await drExtend(untouched, by: friend)
        let mine = try await drPost(by: me, in: group, hoursAgo: 48, kind: .bookReport)
        try await drExtend(mine, by: me)

        let report = try await drReport(for: me)
        XCTAssertEqual(report.totalCount, 0)
    }

    func testExpiredPostsAndOtherGroupsAreLeftOut() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let mine = try await fixtures.group(admin: me, members: [friend])
        let notMine = try await fixtures.group("남의 모임", admin: friend)
        try await drPost(by: friend, in: mine, expiresIn: -60)
        try await drPost(by: friend, in: notMine)

        let report = try await drReport(for: me)
        XCTAssertEqual(report.totalCount, 0)
    }
}

final class DailyReportSweepTests: DailyReportDatabaseTestCase {
    func testSendsOnceAndLogs() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(admin: me, members: [friend])
        try await drPost(by: friend, in: group, hoursAgo: 2)
        try await drMakeDue(me)
        try await drMakeDue(friend) // nothing for the friend: their own post does not count

        let outcome = try await DailyReportSweep.run(
            on: db, config: app.pilgrimConfig, now: drNow, logger: app.logger)
        XCTAssertEqual(outcome, DailyReportSweep.Outcome(sent: 1, skipped: 1))

        let logs = try await drLogs()
        let mine = try XCTUnwrap(logs.first { $0.$user.id == me.id })
        XCTAssertEqual(mine.status, .sent)
        XCTAssertEqual(mine.itemCount, 1)
        XCTAssertEqual(mine.reportDate, LocalDate(drNow, in: drUTC).description)
        XCTAssertEqual(logs.first { $0.$user.id == friend.id }?.status, .skipped)

        let outbox = try await drOutbox()
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.first?.$recipient.id, me.id)
        XCTAssertEqual(outbox.first?.payload, .dailyReport(itemCount: 1))
        XCTAssertEqual(
            outbox.first?.collapseID, DailyReportSweep.collapseID(for: LocalDate(drNow, in: drUTC)))

        // The next minute nothing happens again.
        let again = try await DailyReportSweep.run(
            on: db, config: app.pilgrimConfig, now: drNow + 60, logger: app.logger)
        XCTAssertEqual(again, DailyReportSweep.Outcome())
        let logCount = try await drLogs().count
        let outboxCount = try await drOutbox().count
        XCTAssertEqual(logCount, 2)
        XCTAssertEqual(outboxCount, 1)
    }

    func testNotDueYetOrTurnedOff() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let off = try await fixtures.user("끔")
        let group = try await fixtures.group(admin: friend, members: [me, off])
        try await drPost(by: friend, in: group)
        // Noon UTC today; my report is at 12:01, the other user's at 00:00 but turned off.
        let noon = LocalDate(drNow, in: drUTC).startOfDay(in: drUTC) + 12 * 3_600
        me.timeZone = "UTC"
        me.dailyReportMinute = 12 * 60 + 1
        try await me.update(on: db)
        off.timeZone = "UTC"
        off.dailyReportMinute = 0
        off.dailyReportEnabled = false
        try await off.update(on: db)

        let outcome = try await DailyReportSweep.run(
            on: db, config: app.pilgrimConfig, now: noon, logger: app.logger)
        XCTAssertEqual(outcome.sent, 0)
        let logs = try await drLogs()
        XCTAssertFalse(logs.contains { $0.$user.id == me.id || $0.$user.id == off.id })

        let later = try await DailyReportSweep.run(
            on: db, config: app.pilgrimConfig, now: noon + 60, logger: app.logger)
        XCTAssertEqual(later.sent + later.skipped, 1)
        let logsLater = try await drLogs()
        XCTAssertTrue(logsLater.contains { $0.$user.id == me.id })
        XCTAssertFalse(logsLater.contains { $0.$user.id == off.id })
    }

    func testRegisteredJobRuns() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(admin: me, members: [friend])
        try await drPost(by: friend, in: group)
        try await drMakeDue(me)

        let job = try XCTUnwrap(app.workerJobs.jobs.first { $0.name == "dailyReport" })
        XCTAssertEqual(job.lockKey, WorkerLockKey.dailyReport)
        let result = await WorkerRunner(application: app, clock: { [now = drNow] in now }).runOnce(
            job)
        XCTAssertEqual(result, .ran)
        let outboxCount = try await drOutbox().count
        XCTAssertEqual(outboxCount, 1)
    }
}

final class DailyReportRouteTests: DailyReportDatabaseTestCase {
    func testReturnsTheReportForADate() async throws {
        let me = try await fixtures.user("나")
        let friend = try await fixtures.user("민지")
        let group = try await fixtures.group(admin: me, members: [friend])
        let post = try await drPost(by: friend, in: group, hoursAgo: 2)
        try await drMakeDue(me)
        let date = LocalDate(drNow, in: drUTC)

        let response = try await sendV1(.GET, "me/daily-report?date=\(date)", as: me)
        assertStatus(response, .ok)
        let report = try decode(DailyReportResponse.self, from: response)
        XCTAssertEqual(report.date, date)
        XCTAssertEqual(
            report.windowEnd,
            drNow - drNow.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        XCTAssertEqual(report.groups.first?.newPosts.map(\.postId), [try post.requireID()])
        XCTAssertEqual(report.totalCount, 1)

        let latest = try await sendV1(.GET, "me/daily-report", as: me)
        assertStatus(latest, .ok)
        XCTAssertEqual(try decode(DailyReportResponse.self, from: latest).date, date)

        // An earlier day is computed even though nothing was sent.
        let earlier = try await sendV1(
            .GET, "me/daily-report?date=\(date.adding(days: -3))", as: me)
        assertStatus(earlier, .ok)
        XCTAssertEqual(try decode(DailyReportResponse.self, from: earlier).totalCount, 0)
    }

    func testRejectsABadDateAndAnonymousRequests() async throws {
        let me = try await fixtures.user("나")
        let bad = try await sendV1(.GET, "me/daily-report?date=2026-13-01", as: me)
        try assertError(bad, 422, .validationFailed)
        let anonymous = try await sendV1(.GET, "me/daily-report", as: nil)
        XCTAssertEqual(anonymous.status, .unauthorized)
    }
}
