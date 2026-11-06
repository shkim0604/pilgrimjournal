#if canImport(XCTest)
    import Foundation
    import JournalData
    import JournalDomain
    import JournalSearch
    import XCTest

    @testable import PilgrimJournal

    @MainActor
    final class AppModelPrayerTests: XCTestCase {
        private var root: URL!
        private var repository: InMemoryJournalRepository!
        private var model: AppModel!

        override func setUp() async throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "pilgrim-prayer-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            let paths = JournalPaths(root: root)
            try paths.prepare()
            repository = InMemoryJournalRepository()
            model = try AppModel(
                repository: repository,
                importStore: InMemoryImportStore(),
                searchIndex: JournalSearchIndex(
                    url: paths.search.appending(path: "prayer.sqlite")
                ),
                paths: paths,
                cloudAccountMonitor: CloudAccountMonitor(
                    containerIdentifier: "iCloud.test.PilgrimJournal"
                )
            )
        }

        override func tearDown() async throws {
            model = nil
            repository = nil
            if let root { try? FileManager.default.removeItem(at: root) }
        }

        @discardableResult
        private func savePrayerNote(
            title: String,
            topics: [PrayerTopic],
            at date: Date = .now
        ) throws -> JournalEntryRecord {
            try repository.save(
                JournalEntryDraft(
                    kind: .prayer, title: title, occurredAt: date,
                    details: EntryDetails(prayerTopics: topics)),
                deviceID: "test", at: date)
        }

        func testPrayerScopeResetsOnKindChange() throws {
            model.selectKind(.prayer)
            model.selectPrayerScope(.ongoing)
            XCTAssertEqual(model.prayerScope, .ongoing)
            model.selectKind(.diary)
            XCTAssertEqual(model.prayerScope, .notes)
            model.selectKind(.prayer)
            XCTAssertEqual(model.prayerScope, .notes)
        }

        func testOngoingScopeAggregatesAcrossMoreThanFiveHundredNotes() throws {
            for index in 0..<501 {
                try savePrayerNote(
                    title: "노트 \(index)",
                    topics: [PrayerTopic(text: "제목 \(index)")],
                    at: Date(timeIntervalSince1970: TimeInterval(index)))
            }
            model.selectKind(.prayer)
            model.selectPrayerScope(.ongoing)
            XCTAssertEqual(model.ongoingPrayerItems.count, 501)
            XCTAssertEqual(model.entries.count, 501)
            XCTAssertEqual(model.ongoingPrayerItems.first?.entryTitle, "노트 500")
        }

        func testAnsweredScopeGroupsByMonth() throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let november = calendar.date(
                from: DateComponents(year: 2026, month: 11, day: 2))!
            try savePrayerNote(
                title: "노트",
                topics: [
                    PrayerTopic(text: "응답", status: .answered, answeredAt: november),
                    PrayerTopic(text: "기도중"),
                ])
            model.selectKind(.prayer)
            model.selectPrayerScope(.answered)
            XCTAssertEqual(model.answeredPrayerSections.count, 1)
            XCTAssertEqual(
                model.answeredPrayerSections.first?.items.map(\.topic.text), ["응답"])
        }

        func testSetPrayerTopicStatusPersistsAndRequestsEditorReload() throws {
            let topic = PrayerTopic(text: "제목")
            let saved = try savePrayerNote(title: "노트", topics: [topic])
            model.selectKind(.prayer)
            model.selectPrayerScope(.ongoing)
            XCTAssertEqual(model.ongoingPrayerItems.count, 1)

            model.setPrayerTopicStatus(
                entryID: saved.id, topicID: topic.id, status: .answered)

            let after = try XCTUnwrap(repository.entry(id: saved.id))
            XCTAssertEqual(after.details.prayerTopics?.first?.status, .answered)
            XCTAssertNotNil(after.details.prayerTopics?.first?.answeredAt)
            XCTAssertEqual(try repository.revisions(entryID: saved.id).count, 2)
            XCTAssertEqual(model.editorReloadRequest?.entryIDs, [saved.id])
            XCTAssertTrue(model.ongoingPrayerItems.isEmpty)

            model.setPrayerTopicStatus(
                entryID: saved.id, topicID: topic.id, status: .ongoing)
            let reverted = try XCTUnwrap(repository.entry(id: saved.id))
            XCTAssertEqual(reverted.details.prayerTopics?.first?.status, .ongoing)
            XCTAssertNil(reverted.details.prayerTopics?.first?.answeredAt)
        }
    }
#endif
