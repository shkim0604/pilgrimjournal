#if canImport(XCTest)
import Foundation
import JournalDomain
import JournalSearch
import XCTest

final class JournalSearchTests: XCTestCase {
    func testKoreanSubstringAndFilters() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let index = try JournalSearchIndex(url: url)
        let first = makeRecord(
            kind: .bibleStudy,
            title: "요한복음",
            body: "하나님이 세상을 사랑하사",
            tags: ["말씀"],
            date: Date(timeIntervalSince1970: 100)
        )
        let second = makeRecord(
            kind: .diary,
            title: "오늘",
            body: "산책을 했다",
            tags: ["일상"],
            date: Date(timeIntervalSince1970: 200)
        )
        try index.rebuild(from: [first, second])

        XCTAssertEqual(
            try index.search(JournalSearchQuery(text: "세상을")).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            try index.search(JournalSearchQuery(kind: .diary)).map(\.id),
            [second.id]
        )
        XCTAssertEqual(
            try index.search(JournalSearchQuery(tags: ["말씀"])).map(\.id),
            [first.id]
        )
        try index.integrityCheck()
    }

    func testDeletedRecordIsRemoved() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try JournalSearchIndex(url: url)
        var record = makeRecord(
            kind: .diary,
            title: "삭제",
            body: "검색되지 않아야 함",
            tags: [],
            date: .now
        )
        try index.upsert(record)
        XCTAssertEqual(try index.search(JournalSearchQuery(text: "검색")).count, 1)
        record.deletedAt = .now
        try index.upsert(record)
        XCTAssertTrue(try index.search(JournalSearchQuery(text: "검색")).isEmpty)
    }

    func testEntryIDQueueAppliesRemoteUpdateAndRemoval() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let index = try JournalSearchIndex(url: url)
        let coordinator = SearchIndexCoordinator(index: index)
        let record = makeRecord(
            kind: .prayer,
            title: "원격 변경",
            body: "동기화된 기도 제목",
            tags: ["동기화"],
            date: .now
        )

        await coordinator.enqueue([record.id])
        try await coordinator.drain(
            load: { id in id == record.id ? record : nil },
            newHistoryToken: "remote-1"
        )
        XCTAssertEqual(
            try index.search(JournalSearchQuery(text: "동기화된")).map(\.id),
            [record.id]
        )
        let tokenMatches = await !coordinator.needsRebuild(
            expectedHistoryToken: "remote-1"
        )
        XCTAssertTrue(tokenMatches)

        await coordinator.enqueue([record.id])
        try await coordinator.drain(
            load: { _ in nil },
            newHistoryToken: "remote-2"
        )
        XCTAssertTrue(try index.search(JournalSearchQuery(text: "동기화된")).isEmpty)
    }

    func testCombinedFiltersUseOriginalLocalDateAndSearchDetails() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let index = try JournalSearchIndex(url: url)
        let instant = ISO8601DateFormatter().date(
            from: "2026-01-01T15:30:00Z"
        )!
        var matching = makeRecord(
            kind: .bibleStudy,
            title: "새벽 묵상",
            body: "은혜를 기억하다",
            tags: ["말씀", "아침"],
            date: instant
        )
        matching.originalTimeZone = "Asia/Tokyo"
        var sameInstantDifferentLocalDay = makeRecord(
            kind: .bibleStudy,
            title: "저녁 묵상",
            body: "은혜를 기억하다",
            tags: ["말씀"],
            date: instant
        )
        sameInstantDifferentLocalDay.originalTimeZone = "America/Los_Angeles"
        var detailsMatch = makeRecord(
            kind: .reading,
            title: "독서",
            body: "메모",
            tags: [],
            date: instant
        )
        detailsMatch.details.bookTitle = "깊은 독서의 기술"
        try index.rebuild(from: [matching, sameInstantDifferentLocalDay, detailsMatch])

        let queryDate = Calendar.current.date(
            from: DateComponents(year: 2026, month: 1, day: 2)
        )!
        let filtered = try index.search(JournalSearchQuery(
            text: "은혜",
            kind: .bibleStudy,
            tags: ["말씀"],
            startDate: queryDate,
            endDate: queryDate
        ))

        XCTAssertEqual(filtered.map(\.id), [matching.id])
        XCTAssertEqual(
            try index.search(JournalSearchQuery(text: "깊은 독서")).map(\.id),
            [detailsMatch.id]
        )
    }

    private func makeRecord(
        kind: JournalKind,
        title: String,
        body: String,
        tags: [String],
        date: Date
    ) -> JournalEntryRecord {
        JournalEntryRecord(
            id: UUID(),
            kind: kind,
            title: title,
            body: body,
            occurredAt: date,
            originalTimeZone: "Asia/Seoul",
            tags: tags,
            isStarred: false,
            isPinned: false,
            details: EntryDetails(),
            sourceUUID: nil,
            sourceMetadata: nil,
            currentRevisionID: UUID(),
            updatedAt: date,
            modifiedByDeviceID: "test"
        )
    }
}
#endif
