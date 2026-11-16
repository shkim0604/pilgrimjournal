import Foundation

/// A calendar date with no time or time zone, written as `"2026-11-20"` (design.md 2절).
///
/// Used for prayer deadlines (stored as the same string in `posts.deadline`) and Daily Report
/// dates. Proleptic Gregorian calendar.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Fails unless the components name a real Gregorian date (no 2026-02-30).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
            day <= Self.daysInMonth(year: year, month: month)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `YYYY-MM-DD`.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The calendar date of `date` as seen in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        let components = Self.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.year = components.year!
        self.month = components.month!
        self.day = components.day!
    }

    public var description: String {
        let year = String(year).leftPadded(to: 4)
        return "\(year)-\(String(month).leftPadded(to: 2))-\(String(day).leftPadded(to: 2))"
    }

    /// The first moment of this date in `timeZone`. Handles days whose midnight does not exist
    /// (a DST jump at 00:00) by returning the first instant that does.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        let calendar = Self.calendar(timeZone)
        let noon = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return calendar.startOfDay(for: noon)
    }

    /// The date `days` calendar days later (earlier when negative).
    public func adding(days: Int) -> LocalDate {
        LocalDate(julianDay: julianDay + days)
    }

    /// Calendar days from `self` to `other` (positive when `other` is later).
    public func days(until other: LocalDate) -> Int {
        other.julianDay - julianDay
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = LocalDate(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected YYYY-MM-DD, got \(text)")
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Calendar arithmetic

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
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

    /// Julian day number (Fliegel–Van Flandern), for exact day counting without a time zone.
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
        self.day = e - (153 * m + 2) / 5 + 1
        self.month = m + 3 - 12 * (m / 10)
        self.year = 100 * b + d - 4800 + m / 10
    }
}

/// A wall-clock time with minute precision, written as `"22:00"` (design.md 2절).
public struct LocalTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// `0...1439`, the server's `users.daily_report_minute`.
    public init?(minutesSinceMidnight: Int) {
        guard (0..<1440).contains(minutesSinceMidnight) else { return nil }
        self.init(hour: minutesSinceMidnight / 60, minute: minutesSinceMidnight % 60)
    }

    /// Parses exactly `HH:mm`.
    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
            let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// 22:00, the default Daily Report time.
    public static let defaultDailyReport = LocalTime(hour: 22, minute: 0)!

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public var description: String {
        "\(String(hour).leftPadded(to: 2)):\(String(minute).leftPadded(to: 2))"
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let time = LocalTime(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected HH:mm, got \(text)")
        }
        self = time
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
