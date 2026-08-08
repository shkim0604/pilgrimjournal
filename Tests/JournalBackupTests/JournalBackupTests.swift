#if canImport(XCTest)
import Foundation
import JournalBackup
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
