import Foundation

/// A deadline found in the text of prayer requests, offered (never applied) when they are
/// posted to a group.
public struct DeadlineSuggestion: Equatable, Sendable {
    public let day: CalendarDay
    /// The line or sentence the date came from.
    public let source: String

    public init(day: CalendarDay, source: String) {
        self.day = day
        self.source = source
    }
}

/// Suggests a deadline for a prayer-request post from the date phrases in its lines
/// ("다음 주 금요일 면접", "11월 20일 수술").
///
/// - Relative phrases count from the day the entry was written, so "내일" in an entry from last
///   week is already past.
/// - Only days from today through today + 365 count, the range a group post's deadline may
///   take. Anything earlier or later is ignored rather than clamped.
/// - When several lines name a day, the latest wins, so no request disappears before its own
///   date (a post ends three days after its deadline).
/// - The selected lines come first. Only when none of them names a day is `context` (the
///   entry's own text) read, sentence by sentence, because the on-device model often drops
///   the date when it rewrites a sentence as a request.
/// - Sentences about something recurring ("매주 금요일", "every Monday") are skipped: they name
///   no single deadline.
public struct DeadlineSuggester: Sendable {
    /// How far ahead a suggestion may be (the group server's limit for deadlines).
    public static let maxDaysAhead = 365

    public let calendar: DeadlineCalendar
    private let resolver: DatePhraseResolver

    /// `calendar` reads "today" (its time zone is the person's).
    public init(calendar: Calendar) {
        self.init(calendar: DeadlineCalendar(calendar))
    }

    public init(calendar: DeadlineCalendar) {
        self.calendar = calendar
        resolver = DatePhraseResolver(calendar: calendar)
    }

    /// The suggestion for `lines` written on `writtenOn`, as seen on `today`.
    public func suggest(
        lines: [String], context: String = "", writtenOn: CalendarDay, today: CalendarDay
    ) -> DeadlineSuggestion? {
        let window = today...today.adding(days: Self.maxDaysAhead)
        if let found = latest(in: lines, writtenOn: writtenOn, window: window) { return found }
        return latest(in: Self.sentences(of: context), writtenOn: writtenOn, window: window)
    }

    /// The suggestion for `lines` of an entry written at `writtenAt` — read in the entry's own
    /// time zone when it has one — as seen at `now` in this calendar's time zone.
    public func suggest(
        lines: [String], context: String = "", writtenAt: Date, entryTimeZone: TimeZone?,
        now: Date
    ) -> DeadlineSuggestion? {
        let entryCalendar = entryTimeZone.map(DeadlineCalendar.init(timeZone:)) ?? calendar
        return suggest(
            lines: lines, context: context, writtenOn: entryCalendar.day(of: writtenAt),
            today: calendar.day(of: now))
    }

    private func latest(
        in texts: [String], writtenOn: CalendarDay, window: ClosedRange<CalendarDay>
    ) -> DeadlineSuggestion? {
        var best: DeadlineSuggestion?
        for text in texts where !Self.isRecurring(text) {
            guard let day = resolver.resolve(text, from: writtenOn), window.contains(day)
            else { continue }
            if best.map({ day > $0.day }) ?? true {
                best = DeadlineSuggestion(
                    day: day, source: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return best
    }

    private static let recurrenceMarkers = [
        "매주", "매일", "매달", "매월", "매년", "마다", "every ", "weekly", "daily",
    ]

    static func isRecurring(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return recurrenceMarkers.contains { lowered.contains($0) }
    }

    /// `text` split into lines and sentences. Image lines (`![](attachment:…)`) are dropped:
    /// they hold an ID, not prose.
    static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("![") }
            .flatMap(splitSentences)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Breaks after a full stop, question or exclamation mark followed by a space. A dot right
    /// after a digit does not end a sentence, so "2026. 11. 20." stays one date.
    private static func splitSentences(_ line: Substring) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        var beforePrevious: Character?
        for character in line {
            let endsSentence =
                previous.map {
                    "!?。".contains($0) || ($0 == "." && beforePrevious?.isNumber != true)
                }
                ?? false
            if character.isWhitespace, endsSentence {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
            beforePrevious = previous
            previous = character
        }
        sentences.append(current)
        return sentences
    }
}
