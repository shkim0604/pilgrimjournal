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
        XCTAssertNotNil(added)

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
        XCTAssertEqual(try repository.allAttachments().first?.binary, sourceData)
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
}

#endif
