#if canImport(XCTest)
import Foundation
import CloudKit
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

final class AppModelNavigationTests: XCTestCase {
    func testCloudSyncErrorRevealsMissingProductionSchema() {
        let nested = NSError(
            domain: CKErrorDomain,
            code: CKError.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type CD_JournalEntryEntity in production schema",
            ]
        )
        let error = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: ["record": nested],
            ]
        )

        XCTAssertEqual(
            cloudSyncErrorPresentation(for: error),
            CloudSyncErrorPresentation(
                message: "CloudKit 프로덕션 스키마가 아직 배포되지 않았습니다.",
                retryable: false
            )
        )
    }

    @MainActor
    func testCloudSyncEventsExposeCompletionAndRefreshImportedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-cloud-events-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "cloud-events.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )
        let completedAt = Date(timeIntervalSince1970: 123)

        model.handleCloudSyncStoreEvent(CloudSyncStoreEvent(
            operation: .exporting,
            completedAt: nil,
            succeeded: false,
            errorDescription: nil
        ))
        XCTAssertEqual(model.syncState, .pending)

        model.handleCloudSyncStoreEvent(CloudSyncStoreEvent(
            operation: .exporting,
            completedAt: completedAt,
            succeeded: true,
            errorDescription: nil
        ))
        XCTAssertEqual(model.syncState, .synced(completedAt))

        let remoteRecord = try repository.save(
            JournalEntryDraft(kind: .diary, title: "다른 기기 기록"),
            deviceID: "remote-device",
            at: completedAt
        )
        model.handleCloudSyncStoreEvent(CloudSyncStoreEvent(
            operation: .importing,
            completedAt: completedAt,
            succeeded: true,
            errorDescription: nil
        ))
        XCTAssertEqual(model.entries.map(\.id), [remoteRecord.id])

        model.handleCloudSyncStoreEvent(CloudSyncStoreEvent(
            operation: .exporting,
            completedAt: completedAt,
            succeeded: false,
            errorDescription: "네트워크 오류"
        ))
        XCTAssertEqual(
            model.syncState,
            .failed(message: "네트워크 오류", retryable: true)
        )
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
    func testMovingSelectedEntryToTrashCannotBeUndoneByEditorAutosave() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-delete-autosave-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .diary, body: "삭제할 기록"),
            deviceID: "test-device",
            at: .now
        )
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "delete-autosave.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.selectEntry(record.id)
        model.moveToTrash(record)
        model.autosaveOnEditorExit(record.draft)

        XCTAssertTrue(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.trashEntries.map(\.id), [record.id])
        XCTAssertNil(model.selectedEntryID)
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

        let created = try XCTUnwrap(model.saveAndReturnRecord(
            JournalEntryDraft(kind: .diary, body: "첫 입력"),
            closeEditor: false,
            selectSavedEntry: false
        ))
        var update = created.draft
        update.body = "이어 쓴 입력"
        let updated = try XCTUnwrap(model.saveAndReturnRecord(
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

        XCTAssertEqual(model.entries.map(\.id), [
            newestPrayer.id,
            olderPrayer.id,
        ])
        XCTAssertEqual(model.selectedEntryID, newestPrayer.id)
        XCTAssertEqual(model.selectedEntry, newestPrayer)
    }
}
#endif
