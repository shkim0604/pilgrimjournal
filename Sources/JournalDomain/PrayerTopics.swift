import Foundation

/// A single prayer topic (기도제목) inside a prayer-note entry.
///
/// Stored as part of `EntryDetails`, so it rides inside the entry's `detailsData` JSON blob:
/// no CloudKit schema field is added, and revisions/backups/kind-moves cover it automatically.
/// All fields except `id`/`text`/`status` are optional so that older blobs (and future blobs
/// with extra keys, e.g. a deadline) keep decoding.
public struct PrayerTopic: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var status: PrayerStatus
    public var memo: String?
    public var answeredAt: Date?
    public var createdAt: Date?
    /// Section (카테고리) this topic belongs to inside its note, e.g. 감사·중보·가족 이름.
    public var category: String?
    /// How the prayer was answered; only meaningful while `status == .answered`.
    public var answerOutcome: PrayerAnswerOutcome?
    /// Free-form note about the answer (응답 메모), separate from the request `memo`.
    public var answerNote: String?

    public init(
        id: UUID = UUID(),
        text: String,
        status: PrayerStatus = .ongoing,
        memo: String? = nil,
        answeredAt: Date? = nil,
        createdAt: Date? = nil,
        category: String? = nil,
        answerOutcome: PrayerAnswerOutcome? = nil,
        answerNote: String? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.memo = memo
        self.answeredAt = answeredAt
        self.createdAt = createdAt
        self.category = category
        self.answerOutcome = answerOutcome
        self.answerNote = answerNote
    }
}

/// How an answered prayer topic was answered: 주심(Yes) / 아니오(No) / 기다려라(Wait).
public enum PrayerAnswerOutcome: String, Codable, CaseIterable, Sendable {
    case yes
    case no
    case wait

    /// Stored-data label used when flattening topics into body text on kind moves.
    public var carryOverLabel: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .wait: return "Wait"
        }
    }
}

/// A prayer topic together with the entry it lives in, for the aggregated 기도중/응답 lists.
public struct PrayerTopicItem: Identifiable, Equatable, Sendable {
    public var topic: PrayerTopic
    public var entryID: UUID
    public var entryTitle: String
    public var entryOccurredAt: Date

    public var id: UUID { topic.id }

    public init(topic: PrayerTopic, entryID: UUID, entryTitle: String, entryOccurredAt: Date) {
        self.topic = topic
        self.entryID = entryID
        self.entryTitle = entryTitle
        self.entryOccurredAt = entryOccurredAt
    }
}

/// Answered topics grouped under the first day of their answer month.
public struct AnsweredPrayerMonthSection: Identifiable, Equatable, Sendable {
    public var month: Date
    public var items: [PrayerTopicItem]

    public var id: Date { month }

    public init(month: Date, items: [PrayerTopicItem]) {
        self.month = month
        self.items = items
    }
}

public enum PrayerTopicAggregator {
    /// Ongoing topics across `entries`, most recent note first, array order within a note.
    public static func ongoing(in entries: [JournalEntryRecord]) -> [PrayerTopicItem] {
        activeEntries(entries)
            .sorted { $0.occurredAt > $1.occurredAt }
            .flatMap { entry in
                (entry.details.prayerTopics ?? [])
                    .filter { $0.status == .ongoing }
                    .map { item(for: $0, in: entry) }
            }
    }

    /// Answered topics grouped by the month of their answer date, newest month and item first.
    /// Topics answered without a date fall back to the entry's `updatedAt`.
    public static func answeredByMonth(
        in entries: [JournalEntryRecord], calendar: Calendar
    ) -> [AnsweredPrayerMonthSection] {
        let dated: [(date: Date, item: PrayerTopicItem)] = activeEntries(entries)
            .flatMap { entry in
                (entry.details.prayerTopics ?? [])
                    .filter { $0.status == .answered }
                    .map {
                        (date: $0.answeredAt ?? entry.updatedAt, item: item(for: $0, in: entry))
                    }
            }
        let grouped = Dictionary(grouping: dated) { element in
            calendar.date(
                from: calendar.dateComponents([.year, .month], from: element.date))
                ?? element.date
        }
        return
            grouped
            .map { month, elements in
                AnsweredPrayerMonthSection(
                    month: month,
                    items: elements.sorted { $0.date > $1.date }.map(\.item))
            }
            .sorted { $0.month > $1.month }
    }

    private static func activeEntries(_ entries: [JournalEntryRecord]) -> [JournalEntryRecord] {
        entries.filter { !$0.isDeleted }
    }

    private static func item(for topic: PrayerTopic, in entry: JournalEntryRecord)
        -> PrayerTopicItem
    {
        PrayerTopicItem(
            topic: topic, entryID: entry.id, entryTitle: entry.title,
            entryOccurredAt: entry.occurredAt)
    }
}

extension EntryDetails {
    /// Ongoing/answered topic counts for list badges, or nil when the entry has no topics.
    public var prayerTopicCounts: (ongoing: Int, answered: Int)? {
        guard let topics = prayerTopics, !topics.isEmpty else { return nil }
        let answered = topics.filter { $0.status == .answered }.count
        return (ongoing: topics.count - answered, answered: answered)
    }
}
