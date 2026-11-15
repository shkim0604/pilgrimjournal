import Foundation
import PilgrimAPI

/// When a user's Daily Report is due (design.md 11절). Pure time arithmetic, no database.
///
/// - The report for local date `D` is due at `D` + `daily_report_minute` in the user's time zone
///   (`users.time_zone`), and covers the 24 hours before that instant.
/// - A wall-clock time that does not exist that day (a DST jump forward skips it) moves to the
///   next time that does exist — the moment the clocks jump. A time that exists twice (clocks
///   going back) uses the first occurrence.
/// - A report is sent once per local date: it is due when the report time of today (local) has
///   passed and no report was logged for today or a later date (`daily_report_log`). A user who
///   moves the time later before it was sent gets it at the new time; one who moves it earlier
///   past the current time gets it right away.
public enum DailyReportSchedule {
    /// The window is always 24 hours, also across DST changes (design.md 11절).
    public static let windowLength: TimeInterval = 86_400

    /// The zone the server falls back to for an unknown `users.time_zone` (the column default).
    public static let fallbackTimeZoneIdentifier = "Asia/Seoul"

    /// `users.time_zone`, or Asia/Seoul when it is not a known IANA identifier.
    public static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? TimeZone(identifier: fallbackTimeZoneIdentifier)!
    }

    /// The instant of `minute` (minutes since local midnight, clamped to `0...1439`) on `date` in
    /// `timeZone`.
    public static func reportTime(on date: LocalDate, minute: Int, in timeZone: TimeZone) -> Date {
        let clamped = min(max(minute, 0), 1_439)
        let utc = TimeZone(identifier: "UTC")!
        // The wall-clock reading, written as if it were UTC.
        let wall = date.startOfDay(in: utc).timeIntervalSince1970 + TimeInterval(clamped * 60)
        func offset(_ seconds: TimeInterval) -> TimeInterval {
            TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds)))
        }
        // Offsets in force around that day (no real zone changes twice within three days).
        let span: TimeInterval = 36 * 3_600
        let offsets = Set([offset(wall - span), offset(wall), offset(wall + span)])
        let matches = offsets.map { wall - $0 }.filter { offset($0) == wall - $0 }
        if let first = matches.min() {
            return Date(timeIntervalSince1970: first)
        }
        // The time falls in a gap: return the transition, the first existing time after it.
        // Before the transition the offset is the smaller one (`before`), after it the larger.
        guard let before = offsets.min(), let after = offsets.max(), before < after else {
            return Date(timeIntervalSince1970: wall - offset(wall))
        }
        var low = (wall - after).rounded(.down) // still on the `before` offset
        var high = (wall - before).rounded(.up) // already on the `after` offset
        while high - low > 1 {
            let middle = ((low + high) / 2).rounded(.down)
            if offset(middle) == after {
                high = middle
            } else {
                low = middle
            }
        }
        return Date(timeIntervalSince1970: high)
    }

    /// `windowEnd` = the report time on `date`, `windowStart` = 24 hours earlier.
    public static func window(on date: LocalDate, minute: Int, in timeZone: TimeZone)
        -> DateInterval
    {
        let end = reportTime(on: date, minute: minute, in: timeZone)
        return DateInterval(start: end - windowLength, end: end)
    }

    /// The local date whose report is due at `now`, or nil.
    ///
    /// `lastReportDate` is the latest `daily_report_log.report_date` of the user; a log for
    /// today, or for a later date (the user moved to a zone that is behind), means nothing is due.
    public static func dueReportDate(
        now: Date, minute: Int, timeZone: TimeZone, lastReportDate: LocalDate?
    ) -> LocalDate? {
        let today = LocalDate(now, in: timeZone)
        guard now >= reportTime(on: today, minute: minute, in: timeZone) else { return nil }
        if let lastReportDate, lastReportDate >= today { return nil }
        return today
    }

    /// The most recently ended window's date: today once today's report time has passed, else
    /// yesterday (`GET /me/daily-report` without `date`).
    public static func latestReportDate(now: Date, minute: Int, timeZone: TimeZone) -> LocalDate {
        let today = LocalDate(now, in: timeZone)
        if now >= reportTime(on: today, minute: minute, in: timeZone) { return today }
        return today.adding(days: -1)
    }
}
