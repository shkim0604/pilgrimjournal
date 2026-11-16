import Foundation
import JournalShareDrafts
import PilgrimAPI

/// Turns the lines picked in the "기도제목 나누기" sheet into a prayer post for the group
/// composer: one item per selected line, the model's who/topic labels kept, and a deadline
/// suggested from the date phrases in the lines (or, failing that, in the entry).
///
/// A suggested deadline only pre-fills the composer's "데드라인 정하기"; with none, the post
/// uses the default visible period. The person still sees and can change both before posting.
enum PrayerRequestGroupDraft {
    /// Labels the model uses for the writer themself; such a line is not about someone else.
    private static let selfLabels: Set<String> = ["나", "저", "본인", "me", "myself", "i"]

    static func items(from rows: [PrayerRequestShareModel.Row]) -> [PrayerItem] {
        rows.filter(\.isSelected).compactMap { row in
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PrayerItem(text: text, topic: row.topic?.rawValue, who: who(row.who))
        }
    }

    static func who(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty, !selfLabels.contains(label.lowercased())
        else { return nil }
        return label
    }

    static func draft(
        rows: [PrayerRequestShareModel.Row], entryBody: String, writtenAt: Date,
        entryTimeZone: TimeZone?, now: Date = Date(), calendar: Calendar = .current
    ) -> GroupPostDraft {
        let items = items(from: rows)
        let suggestion = DeadlineSuggester(calendar: calendar).suggest(
            lines: items.map(\.text), context: entryBody, writtenAt: writtenAt,
            entryTimeZone: entryTimeZone, now: now)
        return GroupPostDraft(
            kind: .prayer, items: items,
            deadline: suggestion.flatMap {
                LocalDate(year: $0.day.year, month: $0.day.month, day: $0.day.day)
            })
    }
}
