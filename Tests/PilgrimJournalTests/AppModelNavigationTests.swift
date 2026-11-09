#if canImport(XCTest)
import Foundation
import CloudKit
import DayOneImport
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

final class AppModelNavigationTests: XCTestCase {
    @MainActor
    func testResetDayOneImportRemovesOnlyOwnedStagingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-import-cleanup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let staged = paths.importStaging.appending(path: "staged.zip")
        try Data("temporary".utf8).write(to: staged)
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "cleanup.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        model.importPreview = DayOneImportPreview(
            archiveURL: staged,
            archiveFingerprint: "fixture",
            exportVersion: "1.0",
            jsonDisplayName: "journal.json",
            items: [],
            duplicateSourceUUIDs: [],
            optionalFieldCounts: [:],
            missingAttachmentCount: 0,
            warnings: []
        )

        model.resetDayOneImport()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.importActivity, .idle)
    }

    @MainActor
    func testNewEntryCapturesCurrentlySelectedNotebook() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-new-entry-notebook-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "new-entry-notebook.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        _ = model.createNotebook(named: "묵상")
        model.selectNotebook("묵상")
        model.beginNewEntry()

        XCTAssertEqual(model.newEntryNotebookName, "묵상")
        XCTAssertTrue(model.isPresentingEditor)
    }

    @MainActor
    func testShowingSettingsClosesTheActiveEditor() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-show-settings-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "show-settings.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.beginNewEntry()
        XCTAssertTrue(model.isPresentingEditor)

        model.showSettings()

        XCTAssertFalse(model.isPresentingEditor)
        XCTAssertNil(model.editingEntry)
        XCTAssertNil(model.selectedEntryID)
    }

    @MainActor
    func testStartingANewEntryFromSettingsLeavesSettings() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-new-from-settings-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "new-from-settings.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.showSettings()
        model.beginNewEntry()

        // The macOS detail column checks settings before the editor, so
        // settings staying up is the toolbar button doing nothing.
        XCTAssertFalse(model.isPresentingSettings)
        XCTAssertTrue(model.isPresentingEditor)
    }

    @MainActor
    func testRestoringABackupReportsAnOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-restore-outcome-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        _ = try repository.save(
            JournalEntryDraft(kind: .diary, title: "백업 대상"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "restore-outcome.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        await model.prepareBackup()
        let backup = try XCTUnwrap(model.backupDocument?.data)
        await model.restoreBackup(data: backup, mode: .merge)

        XCTAssertNil(model.lastRestoreFailureMessage)
        // Without this the operation finishes with nothing on screen, which
        // reads as "nothing happened".
        let outcome = try XCTUnwrap(model.lastOperationOutcome)
        XCTAssertEqual(outcome.title, "병합 복원 완료")
        XCTAssertFalse(outcome.message.isEmpty)
    }

    @MainActor
    func testSelectingMultipleEntriesOutsideBatchModeArmsTrash() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-multi-select-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let first = try repository.save(
            JournalEntryDraft(kind: .diary, title: "첫 기록"),
            deviceID: "test-device",
            at: .now
        )
        let second = try repository.save(
            JournalEntryDraft(kind: .diary, title: "둘째 기록"),
            deviceID: "test-device",
            at: .now
        )
        let remaining = try repository.save(
            JournalEntryDraft(kind: .diary, title: "남길 기록"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "multi-select.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.selectEntries([first.id, second.id])

        XCTAssertFalse(model.isBatchSelecting)
        XCTAssertEqual(model.selectedEntryIDs, [first.id, second.id])
        // The detail column cannot show two notes at once.
        XCTAssertNil(model.selectedEntryID)

        XCTAssertTrue(model.moveSelectedEntriesToTrash())

        XCTAssertEqual(model.entries.map(\.id), [remaining.id])
        XCTAssertEqual(Set(model.trashEntries.map(\.id)), [first.id, second.id])
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
    }

    @MainActor
    func testSelectingOneEntryLeavesExactlyOneRowSelected() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-single-select-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let first = try repository.save(
            JournalEntryDraft(kind: .diary, title: "첫 기록"),
            deviceID: "test-device",
            at: .now
        )
        let second = try repository.save(
            JournalEntryDraft(kind: .diary, title: "둘째 기록"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "single-select.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.selectEntries([first.id, second.id])
        model.selectEntries([second.id])

        // The highlight is driven by selectedEntryIDs, so a stale id here is
        // exactly the "two green cards for one note" report.
        XCTAssertEqual(model.selectedEntryIDs, [second.id])
        XCTAssertEqual(model.selectedEntryID, second.id)

        model.selectEntry(first.id)

        XCTAssertEqual(model.selectedEntryIDs, [first.id])
    }

    @MainActor
    func testRefreshDropsSelectedEntriesHiddenByTheCurrentFilter() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-prune-select-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let diary = try repository.save(
            JournalEntryDraft(kind: .diary, title: "일기"),
            deviceID: "test-device",
            at: .now
        )
        let memo = try repository.save(
            JournalEntryDraft(kind: .memo, title: "메모"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "prune-select.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.selectEntries([diary.id, memo.id])
        model.selectedKind = .memo
        model.refresh()

        XCTAssertEqual(model.selectedEntryIDs, [memo.id])
    }

    @MainActor
    func testAutosaveRecordReturnReusesCreatedIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-autosave-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "autosave.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        let created = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(kind: .diary, body: "첫 입력"),
                closeEditor: false,
                selectSavedEntry: false
            ))
        var update = created.draft
        update.body = "이어 쓴 입력"
        let updated = try XCTUnwrap(
            model.saveAndReturnRecord(
                update,
                closeEditor: false,
                selectSavedEntry: false
            ))

        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(
            try repository.list(kind: nil, includeDeleted: false, limit: 10).count,
            1
        )
        XCTAssertEqual(updated.body, "이어 쓴 입력")
    }

    @MainActor
    func testEmptyExistingDraftReportsSaveFailureAndPreservesStoredRecord() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-empty-edit-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "empty-edit.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        let record = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(kind: .diary, body: "저장된 본문"),
                closeEditor: false,
                selectSavedEntry: false
            ))
        var empty = record.draft
        empty.body = " \n"
        model.autosaveOnEditorExit(empty)
        XCTAssertEqual(model.errorMessage, JournalError.emptyContent.localizedDescription)
        XCTAssertEqual(try repository.entry(id: record.id)?.body, record.body)
        XCTAssertNil(
            model.saveAndReturnRecord(
                empty, closeEditor: false, selectSavedEntry: false
            ))
    }

    @MainActor
    func testSelectingKindShowsNewestMatchingEntry() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-navigation-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let olderPrayer = try repository.save(
            JournalEntryDraft(
                kind: .prayer,
                title: "이전 기도",
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
            deviceID: "test-device",
            at: Date(timeIntervalSince1970: 100)
        )
        let newestPrayer = try repository.save(
            JournalEntryDraft(
                kind: .prayer,
                title: "최신 기도",
                occurredAt: Date(timeIntervalSince1970: 300)
            ),
            deviceID: "test-device",
            at: Date(timeIntervalSince1970: 300)
        )
        _ = try repository.save(
            JournalEntryDraft(
                kind: .diary,
                title: "다른 유형",
                occurredAt: Date(timeIntervalSince1970: 400)
            ),
            deviceID: "test-device",
            at: Date(timeIntervalSince1970: 400)
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "navigation.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.selectKind(.prayer)

        XCTAssertEqual(
            model.entries.map(\.id),
            [
                newestPrayer.id,
                olderPrayer.id,
            ])
        XCTAssertEqual(model.selectedEntryID, newestPrayer.id)
        XCTAssertEqual(model.selectedEntry, newestPrayer)
    }
}
#endif
