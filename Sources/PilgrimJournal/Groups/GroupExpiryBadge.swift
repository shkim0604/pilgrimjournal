import Foundation
import JournalDomain
import PilgrimAPI
import SwiftUI

/// How a group post's deadline and disappearance read on screen. Everything is computed from
/// the server's `expiresAt` (and the prayer `deadline`); the app never recomputes expiry.
enum GroupExpiryText {
    /// Days from today to the deadline day, both in `calendar`'s time zone: 0 on the day,
    /// negative after it.
    static func daysUntilDeadline(_ deadline: LocalDate, now: Date, calendar: Calendar) -> Int {
        let today = LocalDate(now, in: calendar.timeZone)
        return today.days(until: deadline)
    }

    /// "D-3", "D-day", or "기한 지남".
    static func deadlineCountdown(_ deadline: LocalDate, now: Date, calendar: Calendar) -> String {
        let days = daysUntilDeadline(deadline, now: now, calendar: calendar)
        if days > 0 { return "D-\(days)" }
        if days == 0 { return "D-day" }
        return String(localized: "기한 지남")
    }

    /// Whole calendar days until the post disappears, counted from today.
    static func daysUntilExpiry(_ expiresAt: Date, now: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: expiresAt)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// "3일 뒤 사라져요", "5시간 뒤 사라져요" in the last day, "곧 사라져요" in the last hour.
    static func disappearance(_ expiresAt: Date, now: Date, calendar: Calendar) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "사라졌어요") }
        if remaining < 3_600 { return String(localized: "곧 사라져요") }
        if remaining < 86_400 {
            let hours = Int(remaining / 3_600)
            return String(localized: "\(hours)시간 뒤 사라져요")
        }
        let days = max(1, daysUntilExpiry(expiresAt, now: now, calendar: calendar))
        return String(localized: "\(days)일 뒤 사라져요")
    }

    /// The last day the post is still visible: the day of the instant before `expiresAt`. A
    /// deadline post ending at midnight after D + 3 reads "D + 3까지".
    static func lastVisibleDay(_ expiresAt: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: expiresAt.addingTimeInterval(-1))
    }

    /// "11월 23일까지".
    static func visibleUntil(_ expiresAt: Date, calendar: Calendar) -> String {
        let day = lastVisibleDay(expiresAt, calendar: calendar)
        return String(localized: "\(monthDay(day, calendar: calendar))까지")
    }

    /// "11월 20일" in the current locale.
    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// "11월 20일" for a `LocalDate` (no time-zone shift).
    static func monthDay(_ date: LocalDate) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return monthDay(date.startOfDay(in: calendar.timeZone), calendar: calendar)
    }

    /// Whether the post disappears within a day, to tint the badge.
    static func isEndingSoon(_ expiresAt: Date, now: Date) -> Bool {
        expiresAt.timeIntervalSince(now) < 86_400
    }
}

/// "11월 23일까지 · 7일 뒤 사라져요", plus "기한 11월 20일 · D-6" for a prayer deadline.
struct GroupExpiryBadge: View {
    let post: PostResponse
    let now: Date
    var calendar: Calendar = .current

    var body: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            if let deadline = post.deadline {
                Label {
                    Text(
                        "기한 \(GroupExpiryText.monthDay(deadline)) · \(GroupExpiryText.deadlineCountdown(deadline, now: now, calendar: calendar))"
                    )
                } icon: {
                    Image(systemName: "flag")
                }
                .foregroundStyle(JournalTheme.color(for: .amber))
            }
            Label {
                Text(
                    "\(GroupExpiryText.visibleUntil(post.expiresAt, calendar: calendar)) · \(GroupExpiryText.disappearance(post.expiresAt, now: now, calendar: calendar))"
                )
            } icon: {
                Image(systemName: "hourglass")
            }
            .foregroundStyle(endingSoon ? Color.red : JournalTheme.inkSecondary)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }

    private var endingSoon: Bool { GroupExpiryText.isEndingSoon(post.expiresAt, now: now) }
}
