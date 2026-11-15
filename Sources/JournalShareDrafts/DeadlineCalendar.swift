import Foundation

/// A calendar day without a time or time zone, so a date written in an entry, a model's answer
/// and a deadline picker compare exactly. Proleptic Gregorian; the arithmetic is pure, so it
/// never depends on a time zone or a daylight-saving jump.
///
/// Weeks run Monday to Sunday (the Korean convention the date phrases follow): "다음 주
/// 화요일" is the Tuesday of the following Monday-to-Sunday week.
public struct CalendarDay: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// The components as given; use `CalendarDay.valid(_:_:_:)` when they may not name a date.
    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Finds the first `YYYY-M-D` in `text`, e.g. a model's `date` field.
    public init?(iso text: String) {
        guard
            let match = text.firstMatch(of: CalendarDay.isoPattern),
            let year = Int(match.output.1),
            let month = Int(match.output.2),
            let day = Int(match.output.3),
            let valid = CalendarDay.valid(year, month, day)
        else { return nil }
        self = valid
    }

    /// The day if the components name a real date (no 2026-02-30), else nil.
    public static func valid(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay? {
        isValid(year: year, month: month, day: day) ? CalendarDay(year, month, day) : nil
    }

    public static func isValid(year: Int, month: Int, day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
        return day <= lastDay(year: year, month: month)
    }

    /// The number of days in `month` of `year`.
    public static func lastDay(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// (year, month) `offset` months from `day`'s month.
    public static func month(offset: Int, from day: CalendarDay) -> (year: Int, month: Int) {
        let index = day.year * 12 + (day.month - 1) + offset
        return (index / 12, index % 12 + 1)
    }

    /// The day `days` calendar days later (earlier when negative).
    public func adding(days: Int) -> CalendarDay {
        CalendarDay(julianDay: julianDay + days)
    }

    /// Calendar days from `self` to `other` (positive when `other` is later).
    public func days(until other: CalendarDay) -> Int {
        other.julianDay - julianDay
    }

    /// 0 = Monday … 6 = Sunday.
    public var weekdayIndex: Int {
        // Julian day 0 was a Monday.
        ((julianDay % 7) + 7) % 7
    }

    /// The Monday of the Monday-to-Sunday week this day is in.
    public var mondayOfWeek: CalendarDay {
        adding(days: -weekdayIndex)
    }

    /// The last day of this day's month.
    public var endOfMonth: CalendarDay {
        CalendarDay(year, month, CalendarDay.lastDay(year: year, month: month))
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private nonisolated(unsafe) static let isoPattern = #/(\d{4})-(\d{1,2})-(\d{1,2})/#

    /// Julian day number (Fliegel–Van Flandern), for exact day counting.
    private var julianDay: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    private init(julianDay: Int) {
        let a = julianDay + 32044
        let b = (4 * a + 3) / 146097
        let c = a - 146097 * b / 4
        let d = (4 * c + 3) / 1461
        let e = c - 1461 * d / 4
        let m = (5 * e + 2) / 153
        day = e - (153 * m + 2) / 5 + 1
        month = m + 3 - 12 * (m / 10)
        year = 100 * b + d - 4800 + m / 10
    }
}

/// Turns instants into `CalendarDay`s with an injected `Calendar`, so the day an entry was
/// written and "today" are read in the right time zone (the app passes the person's calendar;
/// the share-card eval passes Asia/Seoul). Only the calendar's time zone matters: days are
/// always Gregorian, whatever the calendar's identifier.
public struct DeadlineCalendar: Sendable {
    public let calendar: Calendar

    public init(_ calendar: Calendar) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        self.calendar = gregorian
    }

    /// The Gregorian calendar of `timeZone`.
    public init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.init(calendar)
    }

    /// Asia/Seoul, the zone the share-card eval fixtures are written in.
    public static let seoul = DeadlineCalendar(timeZone: TimeZone(identifier: "Asia/Seoul")!)

    public var timeZone: TimeZone { calendar.timeZone }

    /// The day `date` falls on in this calendar's time zone.
    public func day(of date: Date) -> CalendarDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(parts.year!, parts.month!, parts.day!)
    }

    /// The first moment of `day` in this calendar's time zone (the first instant that exists
    /// when a daylight-saving jump skips midnight).
    public func startOfDay(_ day: CalendarDay) -> Date {
        let noon = calendar.date(
            from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }
}
