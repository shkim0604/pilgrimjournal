#if canImport(XCTest)
import Foundation
import XCTest

@testable import JournalShareDrafts

final class DeadlineCalendarTests: XCTestCase {
    private let thursday = CalendarDay(2026, 10, 15)

    // MARK: CalendarDay

    func testValidationKnowsMonthLengthsAndLeapYears() {
        XCTAssertNil(CalendarDay.valid(2026, 2, 29))
        XCTAssertEqual(CalendarDay.valid(2028, 2, 29), CalendarDay(2028, 2, 29))
        XCTAssertNil(CalendarDay.valid(1900, 2, 29), "century years are not leap years")
        XCTAssertEqual(CalendarDay.valid(2000, 2, 29), CalendarDay(2000, 2, 29))
        XCTAssertNil(CalendarDay.valid(2026, 4, 31))
        XCTAssertNil(CalendarDay.valid(2026, 13, 1))
        XCTAssertNil(CalendarDay.valid(2026, 0, 1))
        XCTAssertNil(CalendarDay.valid(2026, 1, 0))
    }

    func testAddingDaysCrossesMonthsYearsAndLeapDays() {
        XCTAssertEqual(CalendarDay(2026, 12, 31).adding(days: 1), CalendarDay(2027, 1, 1))
        XCTAssertEqual(CalendarDay(2028, 2, 28).adding(days: 1), CalendarDay(2028, 2, 29))
        XCTAssertEqual(CalendarDay(2026, 3, 1).adding(days: -1), CalendarDay(2026, 2, 28))
        XCTAssertEqual(thursday.adding(days: 365), CalendarDay(2027, 10, 15))
        XCTAssertEqual(thursday.days(until: CalendarDay(2027, 10, 15)), 365)
        XCTAssertEqual(CalendarDay(2027, 10, 15).days(until: thursday), -365)
    }

    func testWeekdaysAgreeWithFoundation() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        var day = CalendarDay(2024, 1, 1)
        for _ in 0..<800 {
            let date = gregorian.date(
                from: DateComponents(year: day.year, month: day.month, day: day.day))!
            let foundation = (gregorian.component(.weekday, from: date) + 5) % 7 // 1 = Sunday
            XCTAssertEqual(day.weekdayIndex, foundation, "\(day)")
            day = day.adding(days: 1)
        }
        XCTAssertEqual(thursday.weekdayIndex, 3)
        XCTAssertEqual(thursday.mondayOfWeek, CalendarDay(2026, 10, 12))
        XCTAssertEqual(CalendarDay(2026, 10, 18).mondayOfWeek, CalendarDay(2026, 10, 12))
        XCTAssertEqual(CalendarDay(2026, 10, 19).mondayOfWeek, CalendarDay(2026, 10, 19))
    }

    func testMonthOffsetsAndEnds() {
        XCTAssertEqual(CalendarDay.month(offset: 1, from: CalendarDay(2026, 12, 20)).year, 2027)
        XCTAssertEqual(CalendarDay.month(offset: 1, from: CalendarDay(2026, 12, 20)).month, 1)
        XCTAssertEqual(CalendarDay(2028, 2, 3).endOfMonth, CalendarDay(2028, 2, 29))
        XCTAssertEqual(CalendarDay(2026, 11, 3).endOfMonth, CalendarDay(2026, 11, 30))
    }

    func testISOParsingAndDescription() {
        XCTAssertEqual(CalendarDay(iso: "date: 2026-11-3"), CalendarDay(2026, 11, 3))
        XCTAssertNil(CalendarDay(iso: "2026-02-30"))
        XCTAssertNil(CalendarDay(iso: "곧"))
        XCTAssertEqual(CalendarDay(2026, 1, 5).description, "2026-01-05")
        XCTAssertLessThan(CalendarDay(2026, 1, 5), CalendarDay(2026, 1, 6))
    }

    func testCodableKeepsTheComponentKeys() throws {
        let data = try JSONEncoder().encode(thursday)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        XCTAssertEqual(object, ["year": 2026, "month": 10, "day": 15])
        XCTAssertEqual(try JSONDecoder().decode(CalendarDay.self, from: data), thursday)
    }

    // MARK: DeadlineCalendar

    func testDayOfAnInstantFollowsTheInjectedTimeZone() {
        // 14:30 UTC: 23:30 on the 15th in Seoul, 03:30 on the 16th in Auckland, 04:30 on the
        // 15th in Honolulu.
        let instant = Date(timeIntervalSince1970: 1_794_753_000) // 2026-11-15T14:30:00Z
        XCTAssertEqual(DeadlineCalendar.seoul.day(of: instant), CalendarDay(2026, 11, 15))
        let auckland = DeadlineCalendar(timeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(auckland.day(of: instant), CalendarDay(2026, 11, 16))
        let honolulu = DeadlineCalendar(timeZone: TimeZone(identifier: "Pacific/Honolulu")!)
        XCTAssertEqual(honolulu.day(of: instant), CalendarDay(2026, 11, 15))
        XCTAssertEqual(
            honolulu.day(of: instant.addingTimeInterval(-6 * 3_600)), CalendarDay(2026, 11, 14))
    }

    func testNonGregorianCalendarsStillGiveGregorianDays() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let instant = Date(timeIntervalSince1970: 1_794_753_000)
        XCTAssertEqual(DeadlineCalendar(buddhist).day(of: instant), CalendarDay(2026, 11, 15))
    }

    func testStartOfDayIsMidnightInTheZone() {
        let start = DeadlineCalendar.seoul.startOfDay(CalendarDay(2026, 11, 20))
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_795_100_400)) // 2026-11-19T15:00Z
    }

    // MARK: DatePhraseResolver

    private let resolver = DatePhraseResolver(calendar: .seoul)

    func testKoreanRelativePhrasesCountFromTheEntryDay() {
        XCTAssertEqual(resolver.resolve("내일 면접", from: thursday), CalendarDay(2026, 10, 16))
        XCTAssertEqual(resolver.resolve("모레", from: thursday), CalendarDay(2026, 10, 17))
        XCTAssertEqual(resolver.resolve("글피", from: thursday), CalendarDay(2026, 10, 18))
        XCTAssertEqual(resolver.resolve("10일 뒤 결과", from: thursday), CalendarDay(2026, 10, 25))
        XCTAssertEqual(resolver.resolve("이번 주 일요일", from: thursday), CalendarDay(2026, 10, 18))
        XCTAssertEqual(resolver.resolve("다음 주 화요일", from: thursday), CalendarDay(2026, 10, 20))
        XCTAssertEqual(resolver.resolve("다다음 주 월요일", from: thursday), CalendarDay(2026, 10, 26))
        XCTAssertEqual(resolver.resolve("금요일에 발표", from: thursday), CalendarDay(2026, 10, 16))
        XCTAssertEqual(resolver.resolve("목요일", from: thursday), CalendarDay(2026, 10, 22))
        XCTAssertEqual(resolver.resolve("다음 달 12일", from: thursday), CalendarDay(2026, 11, 12))
        XCTAssertEqual(resolver.resolve("이번 달 말", from: thursday), CalendarDay(2026, 10, 31))
        XCTAssertEqual(resolver.resolve("다음 달 말", from: thursday), CalendarDay(2026, 11, 30))
        XCTAssertEqual(resolver.resolve("연말까지", from: thursday), CalendarDay(2026, 12, 31))
    }

    func testExplicitAndEnglishDates() {
        XCTAssertEqual(resolver.resolve("2027. 1. 3 수술", from: thursday), CalendarDay(2027, 1, 3))
        XCTAssertEqual(resolver.resolve("2026-11-20", from: thursday), CalendarDay(2026, 11, 20))
        XCTAssertEqual(resolver.resolve("11월 3일", from: thursday), CalendarDay(2026, 11, 3))
        XCTAssertEqual(resolver.resolve("1월 5일", from: thursday), CalendarDay(2027, 1, 5))
        XCTAssertEqual(resolver.resolve("Oct 30", from: thursday), CalendarDay(2026, 10, 30))
        XCTAssertEqual(resolver.resolve("next Friday", from: thursday), CalendarDay(2026, 10, 23))
        XCTAssertEqual(resolver.resolve("this Sunday", from: thursday), CalendarDay(2026, 10, 18))
        XCTAssertEqual(resolver.resolve("tomorrow", from: thursday), CalendarDay(2026, 10, 16))
        XCTAssertEqual(
            resolver.resolve("다음 주 화요일(10월 21일)", from: thursday), CalendarDay(2026, 10, 21))
    }

    func testUnknownOrImpossiblePhrases() {
        XCTAssertNil(resolver.resolve("곧", from: thursday))
        XCTAssertNil(resolver.resolve("this month", from: thursday))
        XCTAssertNil(resolver.resolve("2월 30일", from: thursday))
        XCTAssertNil(resolver.resolve("다음 달 30일", from: CalendarDay(2027, 1, 10)))
        XCTAssertNil(resolver.resolve("99999999999999999999일 뒤", from: thursday))
    }

    func testResolvingAnInstantUsesTheInjectedCalendar() {
        // 2026-10-15T20:00Z: Friday the 16th in Seoul, still Thursday the 15th in New York.
        let instant = Date(timeIntervalSince1970: 1_792_094_400)
        XCTAssertEqual(
            resolver.resolve("내일", writtenAt: instant), CalendarDay(2026, 10, 17))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(
            DatePhraseResolver(calendar: newYork).resolve("내일", writtenAt: instant),
            CalendarDay(2026, 10, 16))
    }
}
#endif
