#if canImport(XCTest)
import Foundation
import CloudKit
import DayOneImport
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

extension AppModelNavigationTests {
    @MainActor
    func testChangingKindSanitizesDetailsAndRecordsARevision() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-navigation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "navigation.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        let prayer = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(
                    kind: .prayer,
                    title: "응답을 기다리며",
                    body: "본문",
                    details: EntryDetails(prayerStatus: .answered)
                )
            )
        )
        XCTAssertEqual(prayer.details.prayerStatus, .answered)

        var changed = JournalEntryDraft(
            id: prayer.id,
            kind: .reading,
            title: "응답을 기다리며",
            body: "본문",
            occurredAt: prayer.occurredAt,
            details: EntryDetails(bookTitle: "순전한 기독교")
        )
        changed.notebookName = prayer.notebookName
        let converted = try XCTUnwrap(model.saveAndReturnRecord(changed))

        // Changing the kind drops the details that no longer apply.
        XCTAssertEqual(converted.kind, .reading)
        XCTAssertNil(converted.details.prayerStatus)
        XCTAssertEqual(converted.details.bookTitle, "순전한 기독교")

        // The pre-change state stays recoverable through the revision history.
        let revisions = model.revisions(for: prayer.id)
        XCTAssertFalse(revisions.isEmpty)

        model.selectKind(.prayer)
        XCTAssertFalse(model.entries.contains { $0.id == prayer.id })
        model.selectKind(.reading)
        XCTAssertTrue(model.entries.contains { $0.id == prayer.id })
    }

    @MainActor
    func testRestoringARevisionBringsBackTheEarlierTitle() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-navigation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "navigation.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        let original = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(kind: .diary, title: "처음 제목", body: "처음 본문")
            )
        )
        _ = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(
                    id: original.id,
                    kind: .diary,
                    title: "고친 제목",
                    body: "고친 본문",
                    occurredAt: original.occurredAt
                )
            )
        )

        let revision = try XCTUnwrap(model.revisions(for: original.id).last)
        model.restoreRevision(entryID: original.id, revisionID: revision.id)

        let restored = try XCTUnwrap(repository.entry(id: original.id))
        XCTAssertEqual(restored.title, "처음 제목")
        XCTAssertEqual(model.selectedEntryID, original.id)
        XCTAssertNil(model.errorMessage)
    }
}

#endif
