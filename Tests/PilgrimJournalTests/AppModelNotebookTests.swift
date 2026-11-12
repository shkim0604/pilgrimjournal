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
    func testCreatingAndSelectingNotebookFiltersEntriesAndPersistsCatalog() throws {
        let identifier = "pilgrim-notebook-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-notebook-navigation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        var notebookDraft = JournalEntryDraft(kind: .diary, title: "여행 기록")
        notebookDraft.notebookName = "여행"
        let notebookEntry = try repository.save(
            notebookDraft,
            deviceID: "test-device",
            at: .now
        )
        _ = try repository.save(
            JournalEntryDraft(kind: .diary, title: "일반 기록"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "notebooks.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: defaults
        )

        XCTAssertEqual(model.createNotebook(named: "  여행  "), "여행")
        model.selectNotebook("여행")

        XCTAssertEqual(model.entries.map(\.id), [notebookEntry.id])
        XCTAssertEqual(model.selectedNotebookName, "여행")
        XCTAssertEqual(defaults.stringArray(forKey: "journal-notebooks"), ["여행"])
    }

    @MainActor
    func testNotebookCatalogRecoversNamesBeyondInitialTimelineLimit() throws {
        let identifier = "pilgrim-notebook-recovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-notebook-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()

        var archivedDraft = JournalEntryDraft(
            kind: .diary,
            title: "오래된 노트북 기록",
            occurredAt: Date(timeIntervalSince1970: 0)
        )
        archivedDraft.notebookName = "보관함"
        _ = try repository.save(
            archivedDraft,
            deviceID: "test-device",
            at: Date(timeIntervalSince1970: 0)
        )
        for index in 1...500 {
            _ = try repository.save(
                JournalEntryDraft(
                    kind: .memo,
                    title: "최근 기록 \(index)",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
                ),
                deviceID: "test-device",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "notebook-recovery.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: defaults
        )

        model.refresh()
        XCTAssertFalse(model.notebooks.contains("보관함"))

        model.refreshNotebookCatalog()

        XCTAssertEqual(model.notebooks, ["보관함"])
        XCTAssertEqual(defaults.stringArray(forKey: "journal-notebooks"), ["보관함"])
    }

    @MainActor
    func testDeletingNotebookKeepsEntriesAndClearsAssignments() throws {
        let identifier = "pilgrim-notebook-delete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-notebook-delete-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        var draft = JournalEntryDraft(kind: .memo, title: "보존할 문서")
        draft.notebookName = "임시"
        let entry = try repository.save(
            draft,
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "notebook-delete.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: defaults
        )
        _ = model.createNotebook(named: "임시")
        model.selectNotebook("임시")

        XCTAssertTrue(model.deleteNotebook(named: "임시"))

        XCTAssertTrue(model.notebooks.isEmpty)
        XCTAssertNil(model.selectedNotebookName)
        XCTAssertNil(try repository.entry(id: entry.id)?.notebookName)
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        XCTAssertEqual(
            defaults.stringArray(forKey: "journal-deleted-notebooks"),
            ["임시"]
        )

        XCTAssertNotNil(
            model.saveAndReturnRecord(
                draft,
                closeEditor: false,
                selectSavedEntry: false
            ))
        XCTAssertNil(try repository.entry(id: entry.id)?.notebookName)
    }
}

#endif
