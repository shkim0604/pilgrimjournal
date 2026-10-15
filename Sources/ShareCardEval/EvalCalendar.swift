import Foundation

/// A calendar day without a time or time zone, so fixture labels and model output compare
/// exactly.
struct DayDate: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Finds the first `YYYY-M-D` in `text`, e.g. a model's `date` field.
    init?(iso text: String) {
        guard
            let match = text.firstMatch(of: DayDate.isoPattern),
            let year = Int(match.output.1),
            let month = Int(match.output.2),
            let day = Int(match.output.3),
            EvalCalendar.isValid(year: year, month: month, day: day)
        else { return nil }
        self.init(year, month, day)
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: DayDate, rhs: DayDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private nonisolated(unsafe) static let isoPattern = #/(\d{4})-(\d{1,2})-(\d{1,2})/#
}

/// Korean-convention calendar arithmetic: weeks start on Monday, so "다음 주 화요일" is the
/// Tuesday of the following Monday-to-Sunday week.
enum EvalCalendar {
    static let weekdayNames = ["월", "화", "수", "목", "금", "토", "일"]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        return day <= lastDay(year: year, month: month)
    }

    static func lastDay(year: Int, month: Int) -> Int {
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        return calendar.range(of: .day, in: .month, for: first)!.count
    }

    static func adding(days: Int, to day: DayDate) -> DayDate {
        let date = calendar.date(byAdding: .day, value: days, to: date(day))!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return DayDate(parts.year!, parts.month!, parts.day!)
    }

    /// (year, month) `offset` months from `day`'s month.
    static func month(offset: Int, from day: DayDate) -> (year: Int, month: Int) {
        let index = day.year * 12 + (day.month - 1) + offset
        return (index / 12, index % 12 + 1)
    }

    /// 0 = Monday ... 6 = Sunday.
    static func weekdayIndex(_ day: DayDate) -> Int {
        let weekday = calendar.component(.weekday, from: date(day)) // 1 = Sunday
        return (weekday + 5) % 7
    }

    static func monday(ofWeekContaining day: DayDate) -> DayDate {
        adding(days: -weekdayIndex(day), to: day)
    }

    static func label(_ day: DayDate) -> String {
        "\(day) (\(weekdayNames[weekdayIndex(day)]))"
    }

    private static func date(_ day: DayDate) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
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

/// Resolves the date phrase the model copied out of the entry ("다음 달 12일", "next Friday")
/// in code — the roadmap's "날짜는 코드가 책임진다". Returns nil for phrases it does not know,
/// in which case the pipeline falls back to the model's own date.
enum DatePhraseResolver {
    static func resolve(_ phrase: String, from entry: DayDate) -> DayDate? {
        let text = phrase.lowercased()
        for rule in rules {
            if let day = rule(text, entry) { return day }
        }
        return nil
    }

    private typealias Rule = @Sendable (String, DayDate) -> DayDate?

    private static let weekdayCharacters: [Character] = ["월", "화", "수", "목", "금", "토", "일"]
    private static let englishWeekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    private static let englishMonths = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    // Most specific first: an explicit date beats a relative phrase in the same text, so
    // "다음 주 화요일(10월 20일)" resolves from "10월 20일".
    private static let rules: [Rule] = [
        { text, _ in
            guard
                let m = text.firstMatch(of: #/(\d{4})\s*[년.\-/]\s*(\d{1,2})\s*[월.\-/]\s*(\d{1,2})/#)
            else { return nil }
            return valid(Int(m.output.1)!, Int(m.output.2)!, Int(m.output.3)!)
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
            let month = EvalCalendar.month(offset: m.output.1 == "다음" ? 1 : 0, from: entry)
            return valid(month.year, month.month, Int(m.output.2)!)
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
            let month = EvalCalendar.month(offset: offset, from: entry)
            return DayDate(
                month.year, month.month, EvalCalendar.lastDay(year: month.year, month: month.month))
        },
        { text, entry in
            if text.contains("글피") { return EvalCalendar.adding(days: 3, to: entry) }
            if text.contains("모레") { return EvalCalendar.adding(days: 2, to: entry) }
            if text.contains("내일") || text.contains("tomorrow") {
                return EvalCalendar.adding(days: 1, to: entry)
            }
            return nil
        },
        { text, entry in
            guard let m = text.firstMatch(of: #/(\d+)\s*일\s*(뒤|후)/#) else { return nil }
            return EvalCalendar.adding(days: Int(m.output.1)!, to: entry)
        },
        { text, entry in
            text.contains(#/연말|올해\s*말/#) ? DayDate(entry.year, 12, 31) : nil
        },
        { text, entry in
            // A bare weekday ("금요일에 발표") means the next one after the entry date.
            guard let m = text.firstMatch(of: #/([월화수목금토일])요일/#) else { return nil }
            let target = weekdayCharacters.firstIndex(of: m.output.1.first!)!
            let ahead = (target - EvalCalendar.weekdayIndex(entry) + 7) % 7
            return EvalCalendar.adding(days: ahead == 0 ? 7 : ahead, to: entry)
        },
    ]

    private static func valid(_ year: Int, _ month: Int, _ day: Int) -> DayDate? {
        EvalCalendar.isValid(year: year, month: month, day: day) ? DayDate(year, month, day) : nil
    }

    /// A month/day without a year is a deadline, so a date already past rolls to next year.
    private static func upcoming(month: Int, day: Int, from entry: DayDate) -> DayDate? {
        guard let thisYear = valid(entry.year, month, day) else { return nil }
        return thisYear < entry ? valid(entry.year + 1, month, day) : thisYear
    }

    private static func weekday(_ index: Int, _ weeksAhead: Int, _ entry: DayDate) -> DayDate {
        let monday = EvalCalendar.monday(ofWeekContaining: entry)
        return EvalCalendar.adding(days: weeksAhead * 7 + index, to: monday)
    }
}
