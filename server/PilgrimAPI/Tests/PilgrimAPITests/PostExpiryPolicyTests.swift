#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

final class PostExpiryPolicyTests: XCTestCase {
    private let policy = PostExpiryPolicy()
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let day: TimeInterval = 86_400

    private func utc(_ text: String) -> Date { PilgrimDateFormat.date(from: text)! }

    private func prayer(
        _ deadline: String?, visibleDays: Int? = nil, at createdAt: Date,
        in timeZone: TimeZone, policy: PostExpiryPolicy? = nil
    ) throws -> Date {
        try (policy ?? self.policy).expiresAt(
            kind: .prayer, createdAt: createdAt, deadline: deadline.flatMap(LocalDate.init),
            visibleDays: visibleDays, timeZone: timeZone)
    }

    // MARK: Prayer with a deadline

    func testDeadlineEndsThreeDaysAfterTheDeadlineDayInThePostersZone() throws {
        // specs/group-server: Asia/Seoul, deadline 2026-11-20 → 2026-11-24T00:00+09:00.
        let expires = try prayer("2026-11-20", at: utc("2026-11-14T13:05:00Z"), in: seoul)
        XCTAssertEqual(expires, utc("2026-11-23T15:00:00Z"))
    }

    func testDeadlineTodayIsAllowed() throws {
        let expires = try prayer("2026-11-14", at: utc("2026-11-14T13:05:00Z"), in: seoul)
        XCTAssertEqual(expires, utc("2026-11-17T15:00:00Z"))
    }

    func testDeadlineAcrossTheAutumnDSTChangeEndsAtLocalMidnight() throws {
        // New York leaves DST on 2026-11-01; 2026-11-04 00:00 is EST (UTC-5), not EDT.
        let expires = try prayer("2026-10-31", at: utc("2026-10-30T12:00:00Z"), in: newYork)
        XCTAssertEqual(expires, utc("2026-11-04T05:00:00Z"))
        XCTAssertNotEqual(expires, LocalDate("2026-10-31")!.startOfDay(in: newYork) + 4 * day)
    }

    func testDeadlineAcrossTheSpringDSTChangeEndsAtLocalMidnight() throws {
        // Berlin enters DST on 2026-03-29; 2026-03-31 00:00 is CEST (UTC+2).
        let expires = try prayer("2026-03-27", at: utc("2026-03-20T09:00:00Z"), in: berlin)
        XCTAssertEqual(expires, utc("2026-03-30T22:00:00Z"))
    }

    func testDeadlineExpiryIsTheFirstInstantOfDeadlinePlusFourInManyZones() throws {
        let zones = [
            "Asia/Seoul", "America/New_York", "Europe/Berlin", "America/Santiago",
            "Australia/Lord_Howe", "Pacific/Chatham", "America/St_Johns", "UTC",
        ]
        let deadlines = ["2026-03-27", "2026-04-02", "2026-09-02", "2026-10-31", "2026-12-31"]
        for zoneName in zones {
            let zone = TimeZone(identifier: zoneName)!
            for text in deadlines {
                let deadline = LocalDate(text)!
                let createdAt = deadline.startOfDay(in: zone) - 3_600 * 30
                let expires = try prayer(text, at: createdAt, in: zone)
                XCTAssertEqual(LocalDate(expires, in: zone), deadline.adding(days: 4), zoneName)
                XCTAssertEqual(
                    LocalDate(expires - 1, in: zone), deadline.adding(days: 3), zoneName)
            }
        }
    }

    func testDeadlineInThePastIsRejectedInThePostersZone() throws {
        // 2026-11-14T16:00Z is already 11-15 01:00 in Seoul but still 11-14 in New York.
        let createdAt = utc("2026-11-14T16:00:00Z")
        XCTAssertThrowsError(try prayer("2026-11-14", at: createdAt, in: seoul)) { error in
            XCTAssertEqual(error as? PostExpiryError, .deadlineInPast)
            XCTAssertEqual((error as? PostExpiryError)?.field, "deadline")
            XCTAssertEqual((error as? PostExpiryError)?.apiError.code, .validationFailed)
        }
        XCTAssertNoThrow(try prayer("2026-11-14", at: createdAt, in: newYork))
        XCTAssertThrowsError(try prayer("2025-11-14", at: createdAt, in: newYork))
    }

    func testDeadlineAtMost365DaysAhead() throws {
        let createdAt = utc("2026-11-14T03:00:00Z")
        XCTAssertNoThrow(try prayer("2027-11-14", at: createdAt, in: seoul))
        XCTAssertThrowsError(try prayer("2027-11-15", at: createdAt, in: seoul)) { error in
            XCTAssertEqual(error as? PostExpiryError, .deadlineTooFar)
        }
        XCTAssertNoThrow(
            try policy.validateDeadline(LocalDate("2027-11-14")!, now: createdAt, timeZone: seoul))
    }

    func testDeadlineWithVisibleDaysIsRejected() {
        XCTAssertThrowsError(
            try prayer("2026-11-20", visibleDays: 7, at: utc("2026-11-14T03:00:00Z"), in: seoul)
        ) { error in
            XCTAssertEqual(error as? PostExpiryError, .deadlineWithVisibleDays)
            XCTAssertEqual((error as? PostExpiryError)?.field, "visibleDays")
        }
    }

    // MARK: Prayer without a deadline

    func testVisibleDaysDefaultsToSevenAndAcceptsTheAllowedSet() throws {
        let createdAt = utc("2026-11-14T13:05:00.123Z")
        XCTAssertEqual(try prayer(nil, at: createdAt, in: seoul), createdAt + 7 * day)
        for days in PostExpiryPolicy.allowedVisibleDays {
            XCTAssertEqual(
                try prayer(nil, visibleDays: days, at: createdAt, in: seoul),
                createdAt + Double(days) * day)
        }
        XCTAssertEqual(PostExpiryPolicy.allowedVisibleDays, [3, 7, 14, 30])
        XCTAssertEqual(PostExpiryPolicy.defaultVisibleDays, 7)
    }

    func testOtherVisibleDaysAreRejected() {
        for days in [0, 1, 5, 31, -7] {
            XCTAssertThrowsError(
                try prayer(nil, visibleDays: days, at: utc("2026-11-14T03:00:00Z"), in: seoul)
            ) { error in
                XCTAssertEqual(error as? PostExpiryError, .invalidVisibleDays(days))
            }
        }
    }

    // MARK: Book reports and testimonies

    func testBookReportsAndTestimoniesLastSevenDays() throws {
        let createdAt = utc("2026-11-14T13:05:00Z")
        for kind in [PostKind.bookReport, .testimony] {
            XCTAssertEqual(
                try policy.expiresAt(
                    kind: kind, createdAt: createdAt, deadline: nil, visibleDays: nil,
                    timeZone: seoul),
                createdAt + 7 * day)
        }
    }

    func testOnlyPrayerTakesADeadlineOrVisibleDays() {
        let createdAt = utc("2026-11-14T13:05:00Z")
        for kind in [PostKind.bookReport, .testimony] {
            XCTAssertThrowsError(
                try policy.expiresAt(
                    kind: kind, createdAt: createdAt, deadline: LocalDate("2026-11-20"),
                    visibleDays: nil, timeZone: seoul)
            ) { XCTAssertEqual($0 as? PostExpiryError, .deadlineNotAllowed) }
            XCTAssertThrowsError(
                try policy.expiresAt(
                    kind: kind, createdAt: createdAt, deadline: nil, visibleDays: 7,
                    timeZone: seoul)
            ) { XCTAssertEqual($0 as? PostExpiryError, .visibleDaysNotAllowed) }
        }
    }

    func testExtensionAddsSevenDaysToTheCurrentExpiryEveryTime() {
        let expires = utc("2026-11-21T13:05:00Z")
        XCTAssertEqual(policy.extended(expires), expires + 7 * day)
        XCTAssertEqual(policy.extended(policy.extended(expires)), expires + 14 * day)
    }

    // MARK: Scaled mode (TIME_SCALE_DAY_SECONDS)

    func testScaledModeUsesDayLengthForEveryRule() throws {
        let scaled = PostExpiryPolicy(dayLength: 10)
        XCTAssertTrue(scaled.isScaled)
        XCTAssertFalse(policy.isScaled)
        let createdAt = utc("2026-11-14T13:05:00Z")
        // specs/group-server: a book report at 10-second days is gone after 70 seconds.
        XCTAssertEqual(
            try scaled.expiresAt(
                kind: .bookReport, createdAt: createdAt, deadline: nil, visibleDays: nil,
                timeZone: seoul),
            createdAt + 70)
        XCTAssertEqual(scaled.extended(createdAt + 70), createdAt + 140)
        XCTAssertEqual(try prayer(nil, at: createdAt, in: seoul, policy: scaled), createdAt + 70)
        XCTAssertEqual(
            try prayer(nil, visibleDays: 3, at: createdAt, in: seoul, policy: scaled),
            createdAt + 30)
    }

    func testScaledDeadlineCountsCalendarDaysFromTodayPlusFour() throws {
        let scaled = PostExpiryPolicy(dayLength: 10)
        let createdAt = utc("2026-11-14T13:05:00Z") // 2026-11-14 22:05 in Seoul
        XCTAssertEqual(
            try prayer("2026-11-14", at: createdAt, in: seoul, policy: scaled), createdAt + 40)
        XCTAssertEqual(
            try prayer("2026-11-16", at: createdAt, in: seoul, policy: scaled), createdAt + 60)
        XCTAssertThrowsError(try prayer("2026-11-13", at: createdAt, in: seoul, policy: scaled))
    }
}
#endif
