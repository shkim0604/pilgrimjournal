#if canImport(XCTest)
import Foundation
@testable import JournalBackup
import JournalData
import JournalDomain
import XCTest

final class JournalBackupTests: XCTestCase {
    func testBackupRoundTripAndRestorePlans() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).journalbackup")
        defer { try? FileManager.default.removeItem(at: destination) }
        let entry = makeRecord(title: "백업 기록", date: Date(timeIntervalSince1970: 10))
        let revision = EntryRevisionRecord(
            id: entry.currentRevisionID,
            entryID: entry.id,
            parentRevisionID: nil,
            snapshot: entry.draft,
            createdAt: entry.updatedAt,
            deviceID: "Mac"
        )
        let attachmentRecord = AttachmentRecord(
            entryID: entry.id,
            originalName: "note.txt",
            mimeType: "text/plain",
            checksum: "placeholder",
            byteCount: 4
        )
        let service = JournalBackupService()
        try service.create(
            at: destination,
            entries: [entry],
            revisions: [revision],
            rules: [],
            attachments: [BackupAttachment(
                record: attachmentRecord,
                binary: Data("note".utf8)
            )],
            sourceSnapshots: [
                BackupSourceSnapshot(
                    sourceUUID: "source",
                    rawJSON: Data(#"{"uuid":"source"}"#.utf8)
                ),
            ]
        )

        let contents = try service.readAndValidate(from: destination)
        XCTAssertEqual(contents.entries, [entry])
        XCTAssertEqual(contents.revisions, [revision])
        XCTAssertEqual(contents.attachments[0].binary, Data("note".utf8))
        XCTAssertEqual(contents.sourceSnapshots.count, 1)

        let other = makeRecord(title: "현재에만 있음", date: .now)
        let merge = service.plan(
            contents: contents,
            currentEntries: [other],
            mode: .merge
        )
        XCTAssertEqual(merge.upserts.map(\.id), [entry.id])
        XCTAssertTrue(merge.tombstoneIDs.isEmpty)

        let replace = service.plan(
            contents: contents,
            currentEntries: [other],
            mode: .replace
        )
        XCTAssertEqual(replace.tombstoneIDs, [other.id])
    }

    func testRejectsCorruptedBackup() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).journalbackup")
        defer { try? FileManager.default.removeItem(at: destination) }
        let service = JournalBackupService()
        try service.create(
            at: destination,
            entries: [makeRecord(title: "기록", date: .now)],
            revisions: [],
            rules: [],
            attachments: []
        )
        var data = try Data(contentsOf: destination)
        data[data.count / 2] ^= 0xFF
        try data.write(to: destination)
        XCTAssertThrowsError(try service.readAndValidate(from: destination))
    }

    func testRejectsUnsupportedBackupFormatVersion() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).journalbackup")
        defer { try? FileManager.default.removeItem(at: destination) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let writer = try StoredZipWriter(url: destination)
        try writer.add(
            name: "manifest.json",
            data: encoder.encode(BackupManifest(
                formatVersion: 999,
                files: [:],
                includesSourceSnapshots: false
            ))
        )
        try writer.finish()

        XCTAssertThrowsError(
            try JournalBackupService().readAndValidate(from: destination)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("format version"))
        }
    }

    func testSnapshotExclusionAndAtomicCompletion() throws {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).journalbackup")
        let partial = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
        }
        let service = JournalBackupService()
        try service.create(
            at: destination,
            entries: [makeRecord(title: "원자적 백업", date: .now)],
            revisions: [],
            rules: [],
            attachments: [],
            sourceSnapshots: []
        )

        let contents = try service.readAndValidate(from: destination)
        XCTAssertFalse(contents.manifest.includesSourceSnapshots)
        XCTAssertTrue(contents.sourceSnapshots.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testIntegrityReportFindsBrokenReferencesWithoutMutatingInput() {
        let valid = makeRecord(title: "정상", date: .now)
        let missingRevision = makeRecord(title: "revision 누락", date: .now)
        let orphanEntryID = UUID()
        let orphanRevision = EntryRevisionRecord(
            entryID: orphanEntryID,
            parentRevisionID: nil,
            snapshot: JournalEntryDraft(kind: .diary, body: "고아 revision"),
            deviceID: "test"
        )
        let validRevision = EntryRevisionRecord(
            id: valid.currentRevisionID,
            entryID: valid.id,
            parentRevisionID: nil,
            snapshot: valid.draft,
            deviceID: "test"
        )
        let missingBinary = BackupAttachment(
            record: AttachmentRecord(
                entryID: valid.id,
                originalName: "missing.jpg",
                mimeType: "image/jpeg",
                checksum: "missing",
                byteCount: 10,
                state: .failed
            ),
            binary: nil
        )
        let entries = [valid, missingRevision]
        let revisions = [validRevision, orphanRevision]

        let report = JournalIntegrityChecker().inspect(
            entries: entries,
            revisions: revisions,
            attachments: [missingBinary],
            indexedEntryIDs: [valid.id, orphanEntryID],
            expectedSearchHistoryToken: "canonical-2",
            actualSearchHistoryToken: "indexed-1",
            at: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(
            Set(report.issues.map(\.kind)),
            [
                .missingCurrentRevision,
                .orphanRevision,
                .unavailableAttachmentBinary,
                .missingSearchDocument,
                .orphanSearchDocument,
                .searchHistoryTokenMismatch,
            ]
        )
        XCTAssertEqual(entries, [valid, missingRevision])
        XCTAssertEqual(revisions, [validRevision, orphanRevision])
    }

    func testIntegrityReportAcceptsUploadedAttachmentWithoutLocalBinary() {
        let entry = makeRecord(title: "정상", date: .now)
        let revision = EntryRevisionRecord(
            id: entry.currentRevisionID,
            entryID: entry.id,
            parentRevisionID: nil,
            snapshot: entry.draft,
            deviceID: "test"
        )
        let remoteAttachment = BackupAttachment(
            record: AttachmentRecord(
                entryID: entry.id,
                originalName: "remote.jpg",
                mimeType: "image/jpeg",
                checksum: "remote",
                byteCount: 10,
                state: .uploaded
            ),
            binary: nil
        )

        let report = JournalIntegrityChecker().inspect(
            entries: [entry],
            revisions: [revision],
            attachments: [remoteAttachment],
            indexedEntryIDs: [entry.id]
        )

        XCTAssertTrue(report.isHealthy)
    }

    @MainActor
    func testRestoreFailureRollsBackEveryMutationAndCanRetry() throws {
        let repository = InMemoryJournalRepository()
        let current = try repository.save(
            JournalEntryDraft(kind: .memo, title: "복원 전 기록"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 1)
        )
        let valid = makeRecord(
            title: "먼저 적용되지만 롤백될 기록",
            date: Date(timeIntervalSince1970: 2)
        )
        var invalid = makeRecord(
            title: "유효하지 않은 기록",
            date: Date(timeIntervalSince1970: 3)
        )
        invalid.title = ""
        invalid.body = ""
        let contents = BackupContents(
            manifest: BackupManifest(files: [:], includesSourceSnapshots: false),
            entries: [valid, invalid],
            revisions: [],
            rules: [],
            attachments: [],
            sourceSnapshots: []
        )
        let failingPlan = RestorePlan(
            mode: .replace,
            upserts: [valid, invalid],
            conflicts: [],
            tombstoneIDs: [current.id]
        )

        XCTAssertThrowsError(try JournalRestoreExecutor().execute(
            contents: contents,
            plan: failingPlan,
            repository: repository,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 4)
        ))
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: current.id)).isDeleted)
        XCTAssertNil(try repository.entry(id: valid.id))
        XCTAssertTrue(repository.allRestoreEpochs().isEmpty)

        let retryContents = BackupContents(
            manifest: contents.manifest,
            entries: [valid],
            revisions: [],
            rules: [],
            attachments: [],
            sourceSnapshots: []
        )
        let retryResult = try JournalRestoreExecutor().execute(
            contents: retryContents,
            plan: RestorePlan(
                mode: .replace,
                upserts: [valid],
                conflicts: [],
                tombstoneIDs: [current.id]
            ),
            repository: repository,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(retryResult.restored, 1)
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: current.id)).isDeleted)
        XCTAssertEqual(try repository.entry(id: valid.id)?.title, valid.title)
        XCTAssertEqual(repository.allRestoreEpochs().count, 1)
    }

    @MainActor
    func testMergeConflictPreservesNewerCurrentAndReplaceConverges() throws {
        let repository = InMemoryJournalRepository()
        let entryID = UUID()
        let current = try repository.save(
            JournalEntryDraft(id: entryID, kind: .diary, title: "현재의 새 내용"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 20)
        )
        let extra = try repository.save(
            JournalEntryDraft(kind: .memo, title: "백업에 없는 기록"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 20)
        )
        var backup = makeRecord(
            title: "백업의 이전 내용",
            date: Date(timeIntervalSince1970: 10)
        )
        backup.id = entryID
        let backupRevision = EntryRevisionRecord(
            id: backup.currentRevisionID,
            entryID: entryID,
            parentRevisionID: nil,
            snapshot: backup.draft,
            createdAt: backup.updatedAt,
            deviceID: "backup"
        )
        let contents = BackupContents(
            manifest: BackupManifest(files: [:], includesSourceSnapshots: false),
            entries: [backup],
            revisions: [backupRevision],
            rules: [],
            attachments: [],
            sourceSnapshots: []
        )
        let service = JournalBackupService()

        let mergePlan = service.plan(
            contents: contents,
            currentEntries: [current, extra],
            mode: .merge
        )
        XCTAssertEqual(mergePlan.conflicts.count, 1)
        XCTAssertTrue(mergePlan.upserts.isEmpty)
        let mergeResult = try JournalRestoreExecutor().execute(
            contents: contents,
            plan: mergePlan,
            repository: repository,
            deviceID: "restore",
            at: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(mergeResult.conflicts, 1)
        XCTAssertEqual(try repository.entry(id: entryID)?.title, "현재의 새 내용")
        XCTAssertTrue(try repository.revisions(entryID: entryID).contains {
            $0.id == backupRevision.id
        })

        let replacePlan = service.plan(
            contents: contents,
            currentEntries: try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100
            ),
            mode: .replace
        )
        let replaceResult = try JournalRestoreExecutor().execute(
            contents: contents,
            plan: replacePlan,
            repository: repository,
            deviceID: "restore",
            at: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(replaceResult.conflicts, 1)
        XCTAssertEqual(try repository.entry(id: entryID)?.title, "백업의 이전 내용")
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: extra.id)).isDeleted)
        XCTAssertEqual(repository.allRestoreEpochs().map(\.mode), [.merge, .replace])
    }

    private func makeRecord(title: String, date: Date) -> JournalEntryRecord {
        JournalEntryRecord(
            id: UUID(),
            kind: .diary,
            title: title,
            body: "본문",
            occurredAt: date,
            originalTimeZone: "Asia/Seoul",
            tags: ["test"],
            isStarred: false,
            isPinned: false,
            details: EntryDetails(mood: "평안"),
            sourceUUID: nil,
            sourceMetadata: nil,
            currentRevisionID: UUID(),
            updatedAt: date,
            modifiedByDeviceID: "Mac"
        )
    }
}
#endif
