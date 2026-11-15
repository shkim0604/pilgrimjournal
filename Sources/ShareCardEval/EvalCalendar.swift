import Foundation
import JournalShareDrafts

/// A calendar day without a time or time zone, so fixture labels and model output compare
/// exactly. The type lives in `JournalShareDrafts`, where the app uses it for deadline
/// suggestions.
typealias DayDate = CalendarDay

/// Korean-convention calendar arithmetic: weeks start on Monday, so "다음 주 화요일" is the
/// Tuesday of the following Monday-to-Sunday week. A thin layer over `CalendarDay`, kept so the
/// prompt and report code reads as before.
enum EvalCalendar {
    static let weekdayNames = ["월", "화", "수", "목", "금", "토", "일"]

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        CalendarDay.isValid(year: year, month: month, day: day)
    }

    static func lastDay(year: Int, month: Int) -> Int {
        CalendarDay.lastDay(year: year, month: month)
    }

    static func adding(days: Int, to day: DayDate) -> DayDate {
        day.adding(days: days)
    }

    /// (year, month) `offset` months from `day`'s month.
    static func month(offset: Int, from day: DayDate) -> (year: Int, month: Int) {
        CalendarDay.month(offset: offset, from: day)
    }

    /// 0 = Monday ... 6 = Sunday.
    static func weekdayIndex(_ day: DayDate) -> Int {
        day.weekdayIndex
    }

    static func monday(ofWeekContaining day: DayDate) -> DayDate {
        day.mondayOfWeek
    }

    static func label(_ day: DayDate) -> String {
        "\(day) (\(weekdayNames[weekdayIndex(day)]))"
    }
}

/// The calendar block put into the extraction prompt, computed from the entry date so the
/// model does not have to do month or weekday arithmetic itself.
enum CalendarHints {
    static func text(for entryDate: DayDate) -> String {
        let thisMonday = EvalCalendar.monday(ofWeekContaining: entryDate)
        let nextMonday = EvalCalendar.adding(days: 7, to: thisMonday)
        let thisMonth = EvalCalendar.month(offset: 0, from: entryDate)
        let nextMonth = EvalCalendar.month(offset: 1, from: entryDate)
        return [
            "작성일: \(EvalCalendar.label(entryDate))",
            "내일: \(EvalCalendar.label(EvalCalendar.adding(days: 1, to: entryDate)))",
            "모레: \(EvalCalendar.label(EvalCalendar.adding(days: 2, to: entryDate)))",
            "이번 주: \(week(from: thisMonday))",
            "다음 주: \(week(from: nextMonday))",
            "이번 달: \(thisMonth.year)년 \(thisMonth.month)월, 이번 달 말 = "
                + monthEnd(thisMonth).description,
            "다음 달: \(nextMonth.year)년 \(nextMonth.month)월, 다음 달 말 = "
                + monthEnd(nextMonth).description,
            "올해 말: \(DayDate(entryDate.year, 12, 31))",
        ].joined(separator: "\n")
    }

    private static func week(from monday: DayDate) -> String {
        (0..<7).map { offset in
            let day = EvalCalendar.adding(days: offset, to: monday)
            return "\(EvalCalendar.weekdayNames[offset]) \(day)"
        }.joined(separator: ", ")
    }

    private static func monthEnd(_ month: (year: Int, month: Int)) -> DayDate {
        DayDate(month.year, month.month, EvalCalendar.lastDay(year: month.year, month: month.month))
    }
}

extension DatePhraseResolver {
    /// The eval's fixtures are written in Asia/Seoul. The resolver itself lives in
    /// `JournalShareDrafts`, where the app injects the person's calendar.
    static func resolve(_ phrase: String, from entry: DayDate) -> DayDate? {
        DatePhraseResolver(calendar: .seoul).resolve(phrase, from: entry)
    }
}
