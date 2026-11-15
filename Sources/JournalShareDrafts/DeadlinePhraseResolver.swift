import Foundation

/// Resolves a date phrase from an entry ("다음 달 12일", "next Friday", "모레") to a day, in
/// code — the roadmap's "날짜는 코드가 책임진다". Relative phrases count from the day the entry
/// was written, not from today. Returns nil for phrases it does not know.
///
/// The phrase may sit inside a longer sentence: the first rule that matches anywhere wins, and
/// an explicit date beats a relative phrase ("다음 주 화요일(10월 20일)" → 10월 20일).
public struct DatePhraseResolver: Sendable {
    public let calendar: DeadlineCalendar

    /// `calendar` decides which day an instant falls on (`resolve(_:writtenAt:)`).
    public init(calendar: Calendar) {
        self.calendar = DeadlineCalendar(calendar)
    }

    public init(calendar: DeadlineCalendar) {
        self.calendar = calendar
    }

    /// `phrase` read as written on `entry`.
    public func resolve(_ phrase: String, from entry: CalendarDay) -> CalendarDay? {
        let text = phrase.lowercased()
        for rule in Self.rules {
            if let day = rule(text, entry) { return day }
        }
        return nil
    }

    /// `phrase` read as written at `date`, on the day `date` falls on in this calendar.
    public func resolve(_ phrase: String, writtenAt date: Date) -> CalendarDay? {
        resolve(phrase, from: calendar.day(of: date))
    }

    private typealias Rule = @Sendable (String, CalendarDay) -> CalendarDay?

    private static let weekdayCharacters: [Character] = ["월", "화", "수", "목", "금", "토", "일"]
    private static let englishWeekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let englishMonths = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    // Most specific first: an explicit date beats a relative phrase in the same text.
    private static let rules: [Rule] = [
        { text, _ in
            guard
                let m = text.firstMatch(of: #/(\d{4})\s*[년.\-/]\s*(\d{1,2})\s*[월.\-/]\s*(\d{1,2})/#)
            else { return nil }
            return CalendarDay.valid(Int(m.output.1)!, Int(m.output.2)!, Int(m.output.3)!)
        },
        { text, entry in
            guard let m = text.firstMatch(of: #/(\d{1,2})\s*월\s*(\d{1,2})\s*일/#) else { return nil }
            return upcoming(month: Int(m.output.1)!, day: Int(m.output.2)!, from: entry)
        },
        { text, entry in
            guard
                let m = text.firstMatch(
                    of:
                        #/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})\b/#
                ),
                let month = englishMonths.firstIndex(of: String(m.output.1))
            else { return nil }
            return upcoming(month: month + 1, day: Int(m.output.2)!, from: entry)
        },
        { text, entry in
            // "주" is optional: the model rewrites "next Friday" as "다음 금요일".
            guard let m = text.firstMatch(of: #/(다다음|다음|이번)\s*(?:주\s*)?([월화수목금토일])요일/#)
            else { return nil }
            let weeks = ["이번": 0, "다음": 1, "다다음": 2][String(m.output.1)]!
            return weekday(weekdayCharacters.firstIndex(of: m.output.2.first!)!, weeks, entry)
        },
        { text, entry in
            guard
                let m = text.firstMatch(
                    of: #/\b(next|this)\s+(mon|tue|wed|thu|fri|sat|sun)[a-z]*day\b/#),
                let index = englishWeekdays.firstIndex(of: String(m.output.2))
            else { return nil }
            return weekday(index, m.output.1 == "next" ? 1 : 0, entry)
        },
        { text, entry in
            guard
                let m = text.firstMatch(
                    of: #/(다음|이번)\s*달\s*(?:\(\s*\d{1,2}\s*월\s*\)\s*)?(\d{1,2})\s*일/#)
            else { return nil }
            let month = CalendarDay.month(offset: m.output.1 == "다음" ? 1 : 0, from: entry)
            return CalendarDay.valid(month.year, month.month, Int(m.output.2)!)
        },
        { text, entry in
            let offset: Int
            if text.contains(#/다음\s*달\s*(말|마지막)/#) {
                offset = 1
            } else if text.contains(#/이번\s*달\s*(말|마지막)|월말/#) {
                offset = 0
            } else {
                return nil
            }
            let month = CalendarDay.month(offset: offset, from: entry)
            return CalendarDay(month.year, month.month, 1).endOfMonth
        },
        { text, entry in
            if text.contains("글피") { return entry.adding(days: 3) }
            if text.contains("모레") { return entry.adding(days: 2) }
            if text.contains("내일") || text.contains("tomorrow") { return entry.adding(days: 1) }
            return nil
        },
        { text, entry in
            guard let m = text.firstMatch(of: #/(\d+)\s*일\s*(뒤|후)/#),
                let days = Int(m.output.1)
            else { return nil }
            return entry.adding(days: days)
        },
        { text, entry in
            text.contains(#/연말|올해\s*말/#) ? CalendarDay(entry.year, 12, 31) : nil
        },
        { text, entry in
            // A bare weekday ("금요일에 발표") means the next one after the entry date.
            guard let m = text.firstMatch(of: #/([월화수목금토일])요일/#) else { return nil }
            let target = weekdayCharacters.firstIndex(of: m.output.1.first!)!
            let ahead = (target - entry.weekdayIndex + 7) % 7
            return entry.adding(days: ahead == 0 ? 7 : ahead)
        },
    ]

    /// A month/day without a year is a deadline, so a date already past rolls to next year.
    private static func upcoming(month: Int, day: Int, from entry: CalendarDay) -> CalendarDay? {
        guard let thisYear = CalendarDay.valid(entry.year, month, day) else { return nil }
        return thisYear < entry ? CalendarDay.valid(entry.year + 1, month, day) : thisYear
    }

    private static func weekday(_ index: Int, _ weeksAhead: Int, _ entry: CalendarDay)
        -> CalendarDay
    {
        entry.mondayOfWeek.adding(days: weeksAhead * 7 + index)
    }
}
