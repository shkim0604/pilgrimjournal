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
    func testCloudSyncErrorRevealsMissingProductionSchema() {
        let nested = NSError(
            domain: CKErrorDomain,
            code: CKError.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type CD_JournalEntryEntity in production schema"
            ]
        )
        let error = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: ["record": nested]
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

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: nil,
                succeeded: false,
                errorDescription: nil
            ))
        XCTAssertEqual(model.syncState, .pending)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
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
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .importing,
                completedAt: completedAt,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.entries.map(\.id), [remoteRecord.id])

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
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
    func testAccountCheckWithoutCloudReportsLocalOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-manual-sync-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "manual-sync.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        await model.refreshCloudAccountState()

        XCTAssertEqual(model.syncState, .localOnly)
    }

    @MainActor
    func testAccountCheckDoesNotDemoteACompletedSync() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-sync-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "sync-state.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )
        let completedAt = Date(timeIntervalSince1970: 500)
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: completedAt,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.syncState, .synced(completedAt))

        // A healthy account reports no problem, so the completed sync stands.
        // Reporting "pending" here used to strand the UI on 동기화 대기.
        model.applyCloudAccountProblem(nil)

        XCTAssertEqual(model.syncState, .synced(completedAt))
    }

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
    func testMovingMultipleSelectedEntriesToTrashClearsBatchSelection() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-batch-delete-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "batch-delete.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        model.selectEntry(first.id)
        model.beginBatchSelection()
        model.selectedEntryIDs.insert(second.id)

        XCTAssertTrue(model.moveSelectedEntriesToTrash())

        XCTAssertEqual(model.entries.map(\.id), [remaining.id])
        XCTAssertEqual(Set(model.trashEntries.map(\.id)), [first.id, second.id])
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: first.id)).isDeleted)
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: second.id)).isDeleted)
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: remaining.id)).isDeleted)
        XCTAssertTrue(model.selectedEntryIDs.isEmpty)
        XCTAssertFalse(model.isBatchSelecting)
        XCTAssertNil(model.selectedEntryID)
    }

    @MainActor
    func testPermanentDeleteClearsOpenEditorAndTrashRow() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-permanent-delete-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .diary, body: "지울 기록"),
            deviceID: "test-device",
            at: .now
        )
        try repository.moveToTrash(entryID: record.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "permanent-delete.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        model.refreshTrash()
        // A different window can have the trashed entry open in its editor
        // without it being the sidebar selection — permanentlyDelete must
        // check editingEntry independently of selectedEntryID.
        model.editingEntry = try XCTUnwrap(repository.entry(id: record.id))
        model.isPresentingEditor = true
        let attachmentRevisionBefore = model.attachmentRevision

        XCTAssertTrue(model.permanentlyDelete(record))

        XCTAssertNil(try repository.entry(id: record.id))
        XCTAssertTrue(model.trashEntries.isEmpty)
        XCTAssertNil(model.editingEntry)
        XCTAssertFalse(model.isPresentingEditor)
        XCTAssertGreaterThan(model.attachmentRevision, attachmentRevisionBefore)
    }

    @MainActor
    func testAutosaveCannotResurrectPermanentlyDeletedEntry() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-purge-autosave-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .diary, body: "지울 기록"),
            deviceID: "test-device",
            at: .now
        )
        try repository.moveToTrash(entryID: record.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "purge-autosave.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        XCTAssertTrue(model.permanentlyDelete(record))

        // Regression: an editor still holding the pre-purge draft must not
        // resurrect the entry on close.
        model.autosaveOnEditorExit(record.draft)

        XCTAssertNil(try repository.entry(id: record.id))
        XCTAssertTrue(model.entries.isEmpty)
    }

    @MainActor
    func testEmptyTrashPurgesEveryTrashedEntryAndLeavesLiveEntries() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-empty-trash-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let trashedA = try repository.save(
            JournalEntryDraft(kind: .diary, title: "지울 A"),
            deviceID: "test-device",
            at: .now
        )
        let trashedB = try repository.save(
            JournalEntryDraft(kind: .diary, title: "지울 B"),
            deviceID: "test-device",
            at: .now
        )
        let live = try repository.save(
            JournalEntryDraft(kind: .diary, title: "남길 기록"),
            deviceID: "test-device",
            at: .now
        )
        try repository.moveToTrash(entryID: trashedA.id, deviceID: "test-device", at: .now)
        try repository.moveToTrash(entryID: trashedB.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "empty-trash.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        XCTAssertTrue(model.emptyTrash())

        XCTAssertTrue(model.trashEntries.isEmpty)
        XCTAssertEqual(model.entries.map(\.id), [live.id])
        XCTAssertNil(try repository.entry(id: trashedA.id))
        XCTAssertNil(try repository.entry(id: trashedB.id))
        XCTAssertNotNil(try repository.entry(id: live.id))
        // Without this the operation finishes with nothing on screen, which
        // reads as "nothing happened" — same convention as backup/restore.
        let outcome = try XCTUnwrap(model.lastOperationOutcome)
        XCTAssertEqual(outcome.title, "영구 삭제 완료")
        XCTAssertFalse(outcome.message.isEmpty)
    }

    @MainActor
    func testRestoreFromTrashIDsRestoresOnlyTheSelectedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-restore-selection-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let restoreA = try repository.save(
            JournalEntryDraft(kind: .diary, title: "복원할 A"),
            deviceID: "test-device",
            at: .now
        )
        let restoreB = try repository.save(
            JournalEntryDraft(kind: .diary, title: "복원할 B"),
            deviceID: "test-device",
            at: .now
        )
        let stayTrashed = try repository.save(
            JournalEntryDraft(kind: .diary, title: "그대로 휴지통"),
            deviceID: "test-device",
            at: .now
        )
        try repository.moveToTrash(entryID: restoreA.id, deviceID: "test-device", at: .now)
        try repository.moveToTrash(entryID: restoreB.id, deviceID: "test-device", at: .now)
        try repository.moveToTrash(entryID: stayTrashed.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "restore-selection.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.restoreFromTrash(ids: [restoreA.id, restoreB.id])

        XCTAssertEqual(model.trashEntries.map(\.id), [stayTrashed.id])
        XCTAssertEqual(Set(model.entries.map(\.id)), [restoreA.id, restoreB.id])
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: restoreA.id)).isDeleted)
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: restoreB.id)).isDeleted)
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: stayTrashed.id)).isDeleted)
    }

    @MainActor
    func testPermanentDeleteIDsPurgesOnlyTheSelectedEntries() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-purge-selection-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let purgeA = try repository.save(
            JournalEntryDraft(kind: .diary, title: "지울 A"),
            deviceID: "test-device",
            at: .now
        )
        let purgeB = try repository.save(
            JournalEntryDraft(kind: .diary, title: "지울 B"),
            deviceID: "test-device",
            at: .now
        )
        let stayTrashed = try repository.save(
            JournalEntryDraft(kind: .diary, title: "그대로 휴지통"),
            deviceID: "test-device",
            at: .now
        )
        try repository.moveToTrash(entryID: purgeA.id, deviceID: "test-device", at: .now)
        try repository.moveToTrash(entryID: purgeB.id, deviceID: "test-device", at: .now)
        try repository.moveToTrash(entryID: stayTrashed.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "purge-selection.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        XCTAssertTrue(model.permanentlyDelete(ids: [purgeA.id, purgeB.id]))

        XCTAssertEqual(model.trashEntries.map(\.id), [stayTrashed.id])
        XCTAssertNil(try repository.entry(id: purgeA.id))
        XCTAssertNil(try repository.entry(id: purgeB.id))
        XCTAssertNotNil(try repository.entry(id: stayTrashed.id))
    }

    @MainActor
    func testPermanentDeleteRemovesUnreferencedAttachmentFileButKeepsSharedOne() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-purge-cas-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entryA = try repository.save(
            JournalEntryDraft(kind: .diary, title: "A"),
            deviceID: "test-device",
            at: .now
        )
        let entryB = try repository.save(
            JournalEntryDraft(kind: .diary, title: "B"),
            deviceID: "test-device",
            at: .now
        )

        let store = try AttachmentFileStore(root: paths.attachments)
        let sharedData = Data("shared content".utf8)
        let uniqueData = Data("unique content".utf8)
        let sharedForA = try store.store(
            data: sharedData,
            entryID: entryA.id,
            originalName: "shared-a.jpg",
            mimeType: "image/jpeg"
        )
        let sharedForB = try store.store(
            data: sharedData,
            entryID: entryB.id,
            originalName: "shared-b.jpg",
            mimeType: "image/jpeg"
        )
        let unique = try store.store(
            data: uniqueData,
            entryID: entryA.id,
            originalName: "unique.jpg",
            mimeType: "image/jpeg"
        )
        try repository.saveAttachment(sharedForA.record, binary: sharedData)
        try repository.saveAttachment(sharedForB.record, binary: sharedData)
        try repository.saveAttachment(unique.record, binary: uniqueData)

        try repository.moveToTrash(entryID: entryA.id, deviceID: "test-device", at: .now)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "purge-cas.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        XCTAssertTrue(model.permanentlyDelete(entryA))

        XCTAssertEqual(
            try store.data(checksum: sharedForA.record.checksum),
            sharedData
        )
        XCTAssertThrowsError(try store.data(checksum: unique.record.checksum))
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
    func testSharedEditorAttachmentFlowStoresMetadataBinaryAndLocalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-editor-attachment-\(UUID().uuidString)",
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
                url: paths.search.appending(path: "attachments.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        let entry = try XCTUnwrap(
            model.saveAndReturnRecord(
                JournalEntryDraft(kind: .memo, title: "첨부 기록"),
                closeEditor: false,
                selectSavedEntry: false
            ))
        let sourceURL = root.appending(path: "sample.txt")
        let sourceData = Data("첨부 본문".utf8)
        try sourceData.write(to: sourceURL)

        let added = await model.addAttachment(from: sourceURL, to: entry.id)
        XCTAssertTrue(added)

        let attachment = try XCTUnwrap(model.attachments(for: entry.id).first)
        XCTAssertEqual(attachment.originalName, "sample.txt")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.byteCount, Int64(sourceData.count))
        XCTAssertEqual(attachment.state, .local)
        XCTAssertEqual(
            try AttachmentFileStore(root: paths.attachments).data(
                checksum: attachment.checksum
            ),
            sourceData
        )
        XCTAssertEqual(try repository.allAttachments().first?.1, sourceData)
    }

    @MainActor
    func testDeleteAttachmentRemovesUnreferencedFileButKeepsSharedOne() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-delete-attachment-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entryA = try repository.save(
            JournalEntryDraft(kind: .diary, title: "A"),
            deviceID: "test-device",
            at: .now
        )
        let entryB = try repository.save(
            JournalEntryDraft(kind: .diary, title: "B"),
            deviceID: "test-device",
            at: .now
        )
        let store = try AttachmentFileStore(root: paths.attachments)
        let sharedData = Data("shared content".utf8)
        let uniqueData = Data("unique content".utf8)
        let sharedForA = try store.store(
            data: sharedData,
            entryID: entryA.id,
            originalName: "shared-a.jpg",
            mimeType: "image/jpeg"
        )
        let sharedForB = try store.store(
            data: sharedData,
            entryID: entryB.id,
            originalName: "shared-b.jpg",
            mimeType: "image/jpeg"
        )
        let unique = try store.store(
            data: uniqueData,
            entryID: entryA.id,
            originalName: "unique.jpg",
            mimeType: "image/jpeg"
        )
        try repository.saveAttachment(sharedForA.record, binary: sharedData)
        try repository.saveAttachment(sharedForB.record, binary: sharedData)
        try repository.saveAttachment(unique.record, binary: uniqueData)
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "delete-attachment.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )

        model.deleteAttachment(sharedForA.record.id)
        model.deleteAttachment(unique.record.id)

        XCTAssertEqual(model.attachments(for: entryA.id), [])
        XCTAssertEqual(model.attachments(for: entryB.id).map(\.id), [sharedForB.record.id])
        // Shared checksum file survives because entryB's copy still references it.
        XCTAssertEqual(try store.data(checksum: sharedForA.record.checksum), sharedData)
        // The uniquely-referenced file is gone once its only row is deleted.
        XCTAssertThrowsError(try store.data(checksum: unique.record.checksum))
    }

    @MainActor
    func testAttachmentUploadFailureRetryAndSuccessDoNotBlockEntryBody() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-transfer-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .diary, body: "첨부와 무관하게 보이는 본문"),
            deviceID: "Mac",
            at: .now
        )
        let attachment = AttachmentRecord(
            entryID: entry.id,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            checksum: "same-checksum",
            byteCount: 3,
            state: .pending
        )
        try repository.saveAttachment(attachment, binary: Data([1, 2, 3]))
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "transfer.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: .now,
                succeeded: false,
                errorDescription: "iCloud 저장 공간이 부족합니다.",
                errorRetryable: true
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .failed)
        XCTAssertEqual(try repository.entry(id: entry.id)?.body, "첨부와 무관하게 보이는 본문")

        model.retryAttachmentTransfer(attachment.id)
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .pending)
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: .now,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .uploaded)
    }

    @MainActor
    func testExportStartEventMarksPendingAttachmentsUploading() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-uploading-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .diary, body: "테스트 본문"),
            deviceID: "Mac",
            at: .now
        )
        let attachment = AttachmentRecord(
            entryID: entry.id,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            checksum: "checksum",
            byteCount: 3,
            state: .pending
        )
        try repository.saveAttachment(attachment, binary: Data([1, 2, 3]))
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "uploading.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        // The export operation's start-of-work notification (endDate/completedAt
        // still nil) used to be discarded entirely — this is the fix that makes
        // "대기 중" and "전송 중" distinguishable.
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: nil,
                succeeded: false,
                errorDescription: nil
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .uploading)
        XCTAssertFalse(model.isCloudImportInProgress)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: .now,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .uploaded)
    }

    @MainActor
    func testUploadCompletionReachesUploadedEvenWhenStartEventWasMissed() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-missed-start-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .diary, body: "테스트 본문"),
            deviceID: "Mac",
            at: .now
        )
        let attachment = AttachmentRecord(
            entryID: entry.id,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            checksum: "checksum",
            byteCount: 3,
            state: .pending
        )
        try repository.saveAttachment(attachment, binary: Data([1, 2, 3]))
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "missed-start.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        // No start-of-export event observed (e.g. app was backgrounded) — the
        // completion event alone must still carry a .pending attachment to
        // .uploaded, not just .uploading, or it would be stranded forever.
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: .now,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .uploaded)
    }

    @MainActor
    func testUploadFailureWhileUploadingIsRetryable() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-uploading-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .diary, body: "테스트 본문"),
            deviceID: "Mac",
            at: .now
        )
        let attachment = AttachmentRecord(
            entryID: entry.id,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            checksum: "checksum",
            byteCount: 3,
            state: .pending
        )
        try repository.saveAttachment(attachment, binary: Data([1, 2, 3]))
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "uploading-failure.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: nil,
                succeeded: false,
                errorDescription: nil
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .uploading)

        // A failure that arrives while an attachment is mid-upload must still
        // reach .failed, not strand it in .uploading with no retry button.
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: .now,
                succeeded: false,
                errorDescription: "iCloud 저장 공간이 부족합니다.",
                errorRetryable: true
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .failed)
    }

    @MainActor
    func testImportStartAndEndTogglesIsCloudImportInProgress() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-import-in-progress-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "import-in-progress.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        XCTAssertFalse(model.isCloudImportInProgress)
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .importing,
                completedAt: nil,
                succeeded: false,
                errorDescription: nil
            ))
        XCTAssertTrue(model.isCloudImportInProgress)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .importing,
                completedAt: .now,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertFalse(model.isCloudImportInProgress)
    }

    @MainActor
    func testMetadataOnlyAttachmentRequestsLazyDownloadAndKeepsTombstoneHidden() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-download-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .memo, title: "원격 첨부"),
            deviceID: "iPhone",
            at: .now
        )
        let remote = AttachmentRecord(
            entryID: entry.id,
            originalName: "remote.pdf",
            mimeType: "application/pdf",
            checksum: "remote-checksum",
            byteCount: 42,
            state: .uploaded
        )
        var deleted = AttachmentRecord(
            entryID: entry.id,
            originalName: "deleted.jpg",
            mimeType: "image/jpeg",
            checksum: "deleted-checksum",
            byteCount: 1,
            state: .uploaded
        )
        deleted.deletedAt = .now
        try repository.saveAttachment(remote, binary: nil)
        try repository.saveAttachment(deleted, binary: Data([0]))
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "download.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )

        XCTAssertEqual(model.attachments(for: entry.id).map(\.id), [remote.id])
        XCTAssertFalse(model.hasLocalBinary(for: remote.id))
        model.requestAttachmentDownload(remote.id)
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .downloading)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .importing,
                completedAt: .now,
                succeeded: false,
                errorDescription: "네트워크 오류",
                errorRetryable: true
            ))
        XCTAssertEqual(model.attachments(for: entry.id).first?.state, .failed)
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
