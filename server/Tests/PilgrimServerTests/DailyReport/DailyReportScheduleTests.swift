import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

/// Report-time arithmetic and target selection (no database).
final class DailyReportScheduleTests: XCTestCase {
    private static let seoul = TimeZone(identifier: "Asia/Seoul")!
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let tenPM = 22 * 60

    private func instant(_ text: String, file: StaticString = #filePath, line: UInt = #line)
        -> Date
    {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else {
            XCTFail("bad ISO date \(text)", file: file, line: line)
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    private func day(_ text: String) -> LocalDate { LocalDate(text)! }

    private func reportTime(_ date: String, _ minute: Int, _ zone: TimeZone) -> Date {
        DailyReportSchedule.reportTime(on: day(date), minute: minute, in: zone)
    }

    // MARK: - reportTime

    func testSeoulHasNoDST() {
        XCTAssertEqual(
            reportTime("2026-11-15", Self.tenPM, Self.seoul), instant("2026-11-15T13:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-07-01", Self.tenPM, Self.seoul), instant("2026-07-01T13:00:00Z"))
        XCTAssertEqual(reportTime("2026-11-15", 0, Self.seoul), instant("2026-11-14T15:00:00Z"))
        XCTAssertEqual(reportTime("2026-11-15", 1_439, Self.seoul), instant("2026-11-15T14:59:00Z"))
    }

    func testNewYorkAcrossSpringForward() {
        // 2026-03-08: 02:00 EST jumps to 03:00 EDT.
        XCTAssertEqual(
            reportTime("2026-03-07", Self.tenPM, Self.newYork), instant("2026-03-08T03:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-03-08", Self.tenPM, Self.newYork), instant("2026-03-09T02:00:00Z"))
        XCTAssertEqual(reportTime("2026-03-08", 90, Self.newYork), instant("2026-03-08T06:30:00Z"))
        XCTAssertEqual(
            reportTime("2026-03-08", 3 * 60, Self.newYork), instant("2026-03-08T07:00:00Z"))
    }

    func testNewYorkMissingTimeMovesToTheNextExistingTime() {
        // 02:00 and 02:30 do not exist on 2026-03-08; the next existing time is 03:00 EDT.
        XCTAssertEqual(
            reportTime("2026-03-08", 2 * 60, Self.newYork), instant("2026-03-08T07:00:00Z"))
        XCTAssertEqual(reportTime("2026-03-08", 150, Self.newYork), instant("2026-03-08T07:00:00Z"))
        XCTAssertEqual(reportTime("2026-03-08", 179, Self.newYork), instant("2026-03-08T07:00:00Z"))
        // The same time the day before and after exists normally.
        XCTAssertEqual(reportTime("2026-03-07", 150, Self.newYork), instant("2026-03-07T07:30:00Z"))
        XCTAssertEqual(reportTime("2026-03-09", 150, Self.newYork), instant("2026-03-09T06:30:00Z"))
    }

    func testNewYorkRepeatedTimeUsesTheFirstOccurrence() {
        // 2026-11-01: 02:00 EDT falls back to 01:00 EST, so 01:30 happens twice.
        XCTAssertEqual(reportTime("2026-11-01", 90, Self.newYork), instant("2026-11-01T05:30:00Z"))
        XCTAssertEqual(reportTime("2026-11-01", 60, Self.newYork), instant("2026-11-01T05:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-11-01", 2 * 60, Self.newYork), instant("2026-11-01T07:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-10-31", Self.tenPM, Self.newYork), instant("2026-11-01T02:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-11-01", Self.tenPM, Self.newYork), instant("2026-11-02T03:00:00Z"))
    }

    func testBerlinAcrossBothTransitions() {
        // 2026-03-29: 02:00 CET jumps to 03:00 CEST.
        XCTAssertEqual(
            reportTime("2026-03-28", Self.tenPM, Self.berlin), instant("2026-03-28T21:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-03-29", Self.tenPM, Self.berlin), instant("2026-03-29T20:00:00Z"))
        XCTAssertEqual(reportTime("2026-03-29", 135, Self.berlin), instant("2026-03-29T01:00:00Z"))
        // 2026-10-25: 03:00 CEST falls back to 02:00 CET; 02:30 happens twice.
        XCTAssertEqual(reportTime("2026-10-25", 150, Self.berlin), instant("2026-10-25T00:30:00Z"))
        XCTAssertEqual(
            reportTime("2026-10-25", 3 * 60, Self.berlin), instant("2026-10-25T02:00:00Z"))
        XCTAssertEqual(
            reportTime("2026-10-25", Self.tenPM, Self.berlin), instant("2026-10-25T21:00:00Z"))
    }

    func testSkippedCalendarDayMovesToTheNextDay() {
        // Samoa skipped 2011-12-30 entirely (23:59:59 on the 29th, -10, was followed by
        // 00:00 on the 31st, +14).
        let apia = TimeZone(identifier: "Pacific/Apia")!
        XCTAssertEqual(reportTime("2011-12-30", Self.tenPM, apia), instant("2011-12-30T10:00:00Z"))
        XCTAssertEqual(reportTime("2011-12-31", Self.tenPM, apia), instant("2011-12-31T08:00:00Z"))
    }

    func testMinuteIsClamped() {
        XCTAssertEqual(
            reportTime("2026-11-15", 5_000, Self.seoul), reportTime("2026-11-15", 1_439, Self.seoul)
        )
        XCTAssertEqual(
            reportTime("2026-11-15", -5, Self.seoul), reportTime("2026-11-15", 0, Self.seoul))
    }

    func testUnknownTimeZoneFallsBackToSeoul() {
        XCTAssertEqual(DailyReportSchedule.timeZone("Not/AZone").identifier, "Asia/Seoul")
        XCTAssertEqual(DailyReportSchedule.timeZone("Europe/Berlin").identifier, "Europe/Berlin")
    }

    // MARK: - window

    func testWindowIsTheTwentyFourHoursBeforeTheReportTime() {
        let window = DailyReportSchedule.window(
            on: day("2026-11-15"), minute: Self.tenPM, in: Self.seoul)
        XCTAssertEqual(window.end, instant("2026-11-15T13:00:00Z"))
        XCTAssertEqual(window.start, instant("2026-11-14T13:00:00Z"))
    }

    func testWindowStaysTwentyFourHoursOnDSTDays() {
        let spring = DailyReportSchedule.window(
            on: day("2026-03-08"), minute: Self.tenPM, in: Self.newYork)
        XCTAssertEqual(spring.end, instant("2026-03-09T02:00:00Z"))
        XCTAssertEqual(spring.duration, 86_400)
        let autumn = DailyReportSchedule.window(
            on: day("2026-10-25"), minute: Self.tenPM, in: Self.berlin)
        XCTAssertEqual(autumn.end, instant("2026-10-25T21:00:00Z"))
        XCTAssertEqual(autumn.duration, 86_400)
    }

    // MARK: - dueReportDate

    private func due(_ now: String, _ minute: Int, _ zone: TimeZone, last: String? = nil)
        -> LocalDate?
    {
        DailyReportSchedule.dueReportDate(
            now: instant(now), minute: minute, timeZone: zone, lastReportDate: last.map(day))
    }

    func testDueOnceTheLocalReportTimeHasPassed() {
        XCTAssertNil(due("2026-11-15T12:59:59Z", Self.tenPM, Self.seoul))
        XCTAssertEqual(due("2026-11-15T13:00:00Z", Self.tenPM, Self.seoul), day("2026-11-15"))
        XCTAssertEqual(due("2026-11-15T14:59:00Z", Self.tenPM, Self.seoul), day("2026-11-15"))
        // After local midnight it is the next day, whose time has not come yet.
        XCTAssertNil(due("2026-11-15T15:00:00Z", Self.tenPM, Self.seoul))
    }

    func testNotDueTwiceForTheSameDate() {
        XCTAssertNil(due("2026-11-15T13:01:00Z", Self.tenPM, Self.seoul, last: "2026-11-15"))
        XCTAssertEqual(
            due("2026-11-15T13:01:00Z", Self.tenPM, Self.seoul, last: "2026-11-14"),
            day("2026-11-15"))
        // A log for a later date (the user moved west) also counts as done.
        XCTAssertNil(due("2026-11-15T13:01:00Z", Self.tenPM, Self.seoul, last: "2026-11-16"))
    }

    func testUsesTheUsersLocalDateNotUTC() {
        // 22:00 EST on 2026-11-14 is 03:00 UTC on the 15th.
        XCTAssertNil(due("2026-11-15T02:59:00Z", Self.tenPM, Self.newYork))
        XCTAssertEqual(due("2026-11-15T03:00:00Z", Self.tenPM, Self.newYork), day("2026-11-14"))
        XCTAssertNil(due("2026-11-15T03:00:00Z", Self.tenPM, Self.newYork, last: "2026-11-14"))
    }

    func testDueAtTheTransitionWhenTheTimeDoesNotExist() {
        XCTAssertNil(due("2026-03-08T06:59:59Z", 150, Self.newYork))
        XCTAssertEqual(due("2026-03-08T07:00:00Z", 150, Self.newYork), day("2026-03-08"))
        XCTAssertNil(due("2026-03-29T00:59:59Z", 135, Self.berlin))
        XCTAssertEqual(due("2026-03-29T01:00:00Z", 135, Self.berlin), day("2026-03-29"))
    }

    func testDueOnlyOnceOnTheRepeatedHour() {
        // 01:30 on 2026-11-01 NY: due at the first 01:30 (EDT); the second 01:30 (EST) finds
        // the log written the first time.
        XCTAssertNil(due("2026-11-01T05:29:00Z", 90, Self.newYork))
        XCTAssertEqual(due("2026-11-01T05:30:00Z", 90, Self.newYork), day("2026-11-01"))
        XCTAssertNil(due("2026-11-01T06:30:00Z", 90, Self.newYork, last: "2026-11-01"))
    }

    func testChangingTheTimeBeforeItWasSent() {
        let now = "2026-11-15T12:30:00Z" // 21:30 KST
        XCTAssertNil(due(now, Self.tenPM, Self.seoul))
        // Moved to 21:00 (already past) → sent right away; moved to 23:00 → later.
        XCTAssertEqual(due(now, 21 * 60, Self.seoul), day("2026-11-15"))
        XCTAssertNil(due(now, 23 * 60, Self.seoul))
        // Already sent today: a new time does not send it again.
        XCTAssertNil(due(now, 21 * 60, Self.seoul, last: "2026-11-15"))
    }

    // MARK: - latestReportDate

    func testLatestReportDate() {
        XCTAssertEqual(
            DailyReportSchedule.latestReportDate(
                now: instant("2026-11-15T12:59:00Z"), minute: Self.tenPM, timeZone: Self.seoul),
            day("2026-11-14"))
        XCTAssertEqual(
            DailyReportSchedule.latestReportDate(
                now: instant("2026-11-15T13:00:00Z"), minute: Self.tenPM, timeZone: Self.seoul),
            day("2026-11-15"))
        XCTAssertEqual(
            DailyReportSchedule.latestReportDate(
                now: instant("2026-03-01T00:30:00Z"), minute: Self.tenPM, timeZone: Self.berlin),
            day("2026-02-28"))
    }

    // MARK: - Sweep target selection

    func testSweepPicksDueUnsuspendedCandidatesUpToTheLimit() {
        let now = instant("2026-11-15T13:30:00Z") // 22:30 KST, 08:30 EST, 14:30 CET
        let seoulDue = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Asia/Seoul", minute: Self.tenPM)
        let seoulSent = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Asia/Seoul", minute: Self.tenPM,
            lastReportDate: day("2026-11-15"))
        let newYorkLater = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "America/New_York", minute: Self.tenPM,
            lastReportDate: day("2026-11-14"))
        let berlinMorning = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Europe/Berlin", minute: 8 * 60)
        let suspended = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Asia/Seoul", minute: Self.tenPM, suspendedAt: now - 60)
        let suspensionOver = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Asia/Seoul", minute: Self.tenPM, suspendedAt: now - 600,
            suspendedUntil: now - 60)
        let badZone = DailyReportSweep.Candidate(
            userID: UUID(), timeZone: "Nowhere/Land", minute: Self.tenPM)
        let all = [
            seoulDue, seoulSent, newYorkLater, berlinMorning, suspended, suspensionOver, badZone,
        ]

        let due = DailyReportSweep.due(all, now: now)
        XCTAssertEqual(
            due.map(\.userID),
            [seoulDue.userID, berlinMorning.userID, suspensionOver.userID, badZone.userID])
        XCTAssertEqual(due.map(\.date.description), Array(repeating: "2026-11-15", count: 4))
        XCTAssertEqual(due.last?.timeZone.identifier, "Asia/Seoul")

        let limited = DailyReportSweep.due(all, now: now, limit: 2)
        XCTAssertEqual(limited.map(\.userID), [seoulDue.userID, berlinMorning.userID])
    }

    func testCollapseIDNamesTheDate() {
        XCTAssertEqual(
            DailyReportSweep.collapseID(for: day("2026-11-15")), "daily-report-2026-11-15")
    }
}
