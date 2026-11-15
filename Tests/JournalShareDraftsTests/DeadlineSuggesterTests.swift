#if canImport(XCTest)
import Foundation
import XCTest

@testable import JournalShareDrafts

final class DeadlineSuggesterTests: XCTestCase {
    private let suggester = DeadlineSuggester(calendar: .seoul)
    /// Thursday.
    private let entryDay = CalendarDay(2026, 10, 15)

    private func suggest(
        _ lines: [String], context: String = "", writtenOn: CalendarDay? = nil,
        today: CalendarDay? = nil
    ) -> CalendarDay? {
        suggester.suggest(
            lines: lines, context: context, writtenOn: writtenOn ?? entryDay,
            today: today ?? entryDay)?.day
    }

    func testNoDatePhraseSuggestsNothing() {
        XCTAssertNil(suggest([]))
        XCTAssertNil(suggest(["가족의 건강을 위해", "마음의 평안을 위해"]))
        XCTAssertNil(suggest(["  "], context: "오늘은 조용한 하루였다."))
    }

    func testOneLineWithADate() {
        XCTAssertEqual(suggest(["다음 주 금요일 면접을 잘 보도록"]), CalendarDay(2026, 10, 23))
        XCTAssertEqual(suggest(["11월 20일 수술이 잘 되도록"]), CalendarDay(2026, 11, 20))
    }

    func testTheLatestDayWinsSoNoRequestEndsEarly() {
        let lines = ["내일 발표를 잘 하도록", "11월 3일 시험을 위해", "다음 주 화요일 결과가 나오도록"]
        XCTAssertEqual(suggest(lines), CalendarDay(2026, 11, 3))
    }

    func testTheSourceIsTheLineTheDayCameFrom() {
        let suggestion = suggester.suggest(
            lines: ["가족의 건강", "  모레 이사를 무사히 마치도록 "], writtenOn: entryDay,
            today: entryDay)
        XCTAssertEqual(suggestion?.day, CalendarDay(2026, 10, 17))
        XCTAssertEqual(suggestion?.source, "모레 이사를 무사히 마치도록")
    }

    func testRelativePhrasesCountFromTheEntryDayAndPastDaysAreDropped() {
        // Written a week ago: "내일" was last Friday, already past today.
        let lastWeek = CalendarDay(2026, 10, 8)
        XCTAssertNil(suggest(["내일 면접"], writtenOn: lastWeek, today: entryDay))
        XCTAssertEqual(
            suggest(["내일 면접", "다음 달 12일 수술"], writtenOn: lastWeek, today: entryDay),
            CalendarDay(2026, 11, 12))
        // Today itself is a valid deadline.
        XCTAssertEqual(
            suggest(["내일 면접"], writtenOn: CalendarDay(2026, 10, 14), today: entryDay),
            entryDay)
    }

    func testOnlyTheNextYearCounts() {
        let today = entryDay
        XCTAssertEqual(
            suggest(["365일 뒤"], today: today), today.adding(days: 365), "the last day counts")
        XCTAssertNil(suggest(["366일 뒤"], today: today), "too far is ignored, not clamped")
        XCTAssertEqual(
            suggest(["366일 뒤", "모레"], today: today), CalendarDay(2026, 10, 17),
            "a far date does not hide a near one")
        XCTAssertNil(suggest(["2025년 12월 25일"]))
    }

    func testRecurringSentencesAreNotDeadlines() {
        XCTAssertNil(suggest(["매주 금요일 모임을 위해"]))
        XCTAssertNil(suggest(["금요일마다 봉사하는 팀"]))
        XCTAssertNil(suggest(["Pray for the team that meets every Friday"]))
        XCTAssertEqual(
            suggest(["매주 금요일 모임을 위해", "다음 주 수요일 진료"]), CalendarDay(2026, 10, 21))
    }

    func testTranslatedEnglishLinesStillResolve() {
        XCTAssertEqual(
            suggest(["Pray that my friend does well at the interview next Friday"]),
            CalendarDay(2026, 10, 23))
        XCTAssertEqual(suggest(["for the contract due Oct 30"]), CalendarDay(2026, 10, 30))
    }

    func testContextIsReadOnlyWhenNoLineNamesADay() {
        let body = """
            오늘 친구와 통화했다. 친구가 다음 주 화요일에 수술을 받는다고 했다.
            ![](attachment:6F9619FF-8B86-D011-B42D-00C04FC96410 =300x200)
            마음이 많이 쓰인다.
            """
        XCTAssertEqual(
            suggest(["친구의 수술이 잘 되도록"], context: body), CalendarDay(2026, 10, 20))
        XCTAssertEqual(
            suggest(["모레 모임을 위해"], context: body), CalendarDay(2026, 10, 17),
            "a line's own day beats a later one in the entry")
    }

    func testContextIsSplitIntoSentences() {
        let body = "내일 면접이 있다. 결과는 11월 2일에 나온다! 매주 금요일엔 모임."
        XCTAssertEqual(
            DeadlineSuggester.sentences(of: body),
            ["내일 면접이 있다.", "결과는 11월 2일에 나온다!", "매주 금요일엔 모임."])
        XCTAssertEqual(suggest(["면접"], context: body), CalendarDay(2026, 11, 2))
        XCTAssertEqual(
            DeadlineSuggester.sentences(of: "수술은 2026. 11. 20. 오전이다. 기도 부탁."),
            ["수술은 2026. 11. 20. 오전이다.", "기도 부탁."],
            "a dot after a digit keeps the date together")
        XCTAssertEqual(
            suggest(["수술"], context: "수술은 2026. 11. 20. 오전이다."), CalendarDay(2026, 11, 20))
    }

    func testInstantsAreReadInTheEntryAndPersonTimeZones() {
        // 2026-10-15T20:00Z: the 16th in Seoul, the 15th in New York.
        let writtenAt = Date(timeIntervalSince1970: 1_792_094_400)
        let newYork = TimeZone(identifier: "America/New_York")!
        // Written in New York on the 15th, so "내일" is the 16th — read today in Seoul (16th).
        XCTAssertEqual(
            suggester.suggest(
                lines: ["내일 면접"], writtenAt: writtenAt, entryTimeZone: newYork, now: writtenAt)?
                .day,
            CalendarDay(2026, 10, 16))
        // Without its own zone the entry is read in the person's (Seoul): "내일" is the 17th.
        XCTAssertEqual(
            suggester.suggest(
                lines: ["내일 면접"], writtenAt: writtenAt, entryTimeZone: nil, now: writtenAt)?
                .day,
            CalendarDay(2026, 10, 17))
        // A person in New York sees today as the 15th, so the 16th is still ahead.
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = newYork
        XCTAssertEqual(
            DeadlineSuggester(calendar: newYorkCalendar).suggest(
                lines: ["내일 면접"], writtenAt: writtenAt, entryTimeZone: newYork, now: writtenAt)?
                .day,
            CalendarDay(2026, 10, 16))
    }
}
#endif
