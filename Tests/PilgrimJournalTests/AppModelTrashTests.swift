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
}

#endif
