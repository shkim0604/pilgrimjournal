#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class PrayerTopicAggregatorTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func record(
        title: String,
        occurredAt: Date,
        updatedAt: Date? = nil,
        topics: [PrayerTopic]?,
        deletedAt: Date? = nil
    ) -> JournalEntryRecord {
        JournalEntryRecord(
            id: UUID(), kind: .prayer, title: title, body: "",
            occurredAt: occurredAt, originalTimeZone: nil, tags: [],
            isStarred: false, isPinned: false,
            details: EntryDetails(prayerTopics: topics),
            sourceUUID: nil, sourceMetadata: nil,
            currentRevisionID: UUID(),
            updatedAt: updatedAt ?? occurredAt,
            modifiedByDeviceID: "d", deletedAt: deletedAt)
    }

    func testOngoingCollectsAcrossEntriesRecentNoteFirst() {
        let answered = PrayerTopic(
            text: "응답된 것", status: .answered, answeredAt: date(2026, 11, 2))
        let first = PrayerTopic(text: "첫째")
        let second = PrayerTopic(text: "둘째")
        let third = PrayerTopic(text: "셋째")
        let newer = record(
            title: "11월", occurredAt: date(2026, 11, 4),
            topics: [first, answered, second])
        let older = record(title: "10월", occurredAt: date(2026, 10, 12), topics: [third])
        let deleted = record(
            title: "삭제됨", occurredAt: date(2026, 11, 5),
            topics: [PrayerTopic(text: "숨겨짐")], deletedAt: date(2026, 11, 6))
        let bodyOnly = record(title: "본문만", occurredAt: date(2026, 11, 1), topics: nil)

        let items = PrayerTopicAggregator.ongoing(in: [older, deleted, newer, bodyOnly])

        XCTAssertEqual(items.map(\.topic.text), ["첫째", "둘째", "셋째"])
        XCTAssertEqual(items.map(\.entryTitle), ["11월", "11월", "10월"])
        XCTAssertEqual(items[0].entryID, newer.id)
        XCTAssertEqual(items[0].entryOccurredAt, newer.occurredAt)
        XCTAssertEqual(items[0].id, first.id)
    }

    func testAnsweredGroupsByMonthNewestFirst() {
        let november = PrayerTopic(
            text: "11월 응답", status: .answered, answeredAt: date(2026, 11, 2))
        let october = PrayerTopic(
            text: "10월 응답", status: .answered, answeredAt: date(2026, 10, 20))
        let octoberLater = PrayerTopic(
            text: "10월 말 응답", status: .answered, answeredAt: date(2026, 10, 28))
        let noDate = PrayerTopic(text: "날짜 없음", status: .answered)
        let entry = record(
            title: "노트", occurredAt: date(2026, 10, 1),
            updatedAt: date(2026, 9, 15),
            topics: [october, november, noDate, octoberLater])

        let sections = PrayerTopicAggregator.answeredByMonth(
            in: [entry], calendar: utcCalendar)

        XCTAssertEqual(
            sections.map(\.month),
            [
                date(2026, 11, 1), date(2026, 10, 1), date(2026, 9, 1),
            ])
        XCTAssertEqual(sections[0].items.map(\.topic.text), ["11월 응답"])
        XCTAssertEqual(sections[1].items.map(\.topic.text), ["10월 말 응답", "10월 응답"])
        XCTAssertEqual(sections[2].items.map(\.topic.text), ["날짜 없음"])
    }

    func testAnsweredSkipsDeletedEntriesAndOngoingTopics() {
        let entry = record(
            title: "노트", occurredAt: date(2026, 11, 1),
            topics: [PrayerTopic(text: "기도중인 것")])
        let deleted = record(
            title: "삭제", occurredAt: date(2026, 11, 1),
            topics: [
                PrayerTopic(text: "응답", status: .answered, answeredAt: date(2026, 11, 2))
            ],
            deletedAt: date(2026, 11, 3))
        XCTAssertTrue(
            PrayerTopicAggregator.answeredByMonth(in: [entry, deleted], calendar: utcCalendar)
                .isEmpty)
    }

    func testPrayerTopicCounts() {
        let details = EntryDetails(prayerTopics: [
            PrayerTopic(text: "a"),
            PrayerTopic(text: "b", status: .answered, answeredAt: .now),
            PrayerTopic(text: "c"),
        ])
        XCTAssertEqual(details.prayerTopicCounts?.ongoing, 2)
        XCTAssertEqual(details.prayerTopicCounts?.answered, 1)
        XCTAssertNil(EntryDetails().prayerTopicCounts)
    }
}
#endif
