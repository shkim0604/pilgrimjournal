#if canImport(XCTest) && PILGRIM_SWIFTDATA
import Foundation
import JournalData
import JournalDomain
import SwiftData
import XCTest

@MainActor
final class JournalDataTests: XCTestCase {
    private func makeRepository() throws -> SwiftDataJournalRepository {
        SwiftDataJournalRepository(
            container: try JournalContainerFactory.make(inMemory: true)
        )
    }

    func testSaveCreatesRevisionAndCanRestore() throws {
        let repository = try makeRepository()
        let original = try repository.save(
            JournalEntryDraft(kind: .diary, title: "첫 제목", body: "첫 본문"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 1)
        )
        var edited = original.draft
        edited.title = "수정"
        let current = try repository.save(
            edited,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 2)
        )
        let revisions = try repository.revisions(entryID: current.id)
        XCTAssertEqual(revisions.count, 2)
        let originalRevision = try XCTUnwrap(
            revisions.first(where: { $0.snapshot.title == "첫 제목" })
        )
        let restored = try repository.restore(
            entryID: current.id,
            revisionID: originalRevision.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(restored.title, "첫 제목")
        XCTAssertEqual(try repository.revisions(entryID: current.id).count, 3)
    }

    func testSourceUUIDIsIdempotent() throws {
        let repository = try makeRepository()
        let draft = JournalEntryDraft(
            kind: .diary,
            body: "가져온 본문",
            sourceUUID: "DAY-ONE-1"
        )
        _ = try repository.save(draft, deviceID: "Mac", at: .now)
        XCTAssertThrowsError(
            try repository.save(draft, deviceID: "Mac", at: .now)
        )
    }

    func testTrashAndRestore() throws {
        let repository = try makeRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "기도"),
            deviceID: "Mac",
            at: .now
        )
        try repository.moveToTrash(entryID: record.id, deviceID: "Mac", at: .now)
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)
        try repository.restoreFromTrash(entryID: record.id, deviceID: "Mac", at: .now)
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)
    }

    func testClassificationRulesRoundTrip() throws {
        let repository = try makeRepository()
        let rule = ClassificationRuleRecord(
            source: .templateTitle,
            value: "기도",
            targetKind: .prayer,
            priority: 10
        )
        try repository.saveClassificationRule(rule)
        XCTAssertEqual(try repository.classificationRules(), [rule])
        try repository.deleteClassificationRule(id: rule.id)
        XCTAssertTrue(try repository.classificationRules().isEmpty)
    }

    func testCanonicalRecordsEncodeAndDecode() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entryID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let revisionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let draft = JournalEntryDraft(
            id: entryID,
            kind: .reading,
            title: "책 기록",
            body: "본문",
            occurredAt: date,
            originalTimeZone: "Asia/Seoul",
            tags: ["독서", "메모"],
            isStarred: true,
            details: EntryDetails(bookTitle: "테스트 책", bookAuthor: "저자"),
            sourceUUID: "day-one-source",
            sourceMetadata: Data("{\"weather\":\"clear\"}".utf8)
        )
        let entry = JournalEntryRecord(
            id: entryID,
            kind: draft.kind,
            title: draft.title,
            body: draft.body,
            occurredAt: draft.occurredAt,
            originalTimeZone: draft.originalTimeZone,
            tags: draft.tags,
            isStarred: draft.isStarred,
            isPinned: draft.isPinned,
            details: draft.details,
            sourceUUID: draft.sourceUUID,
            sourceMetadata: draft.sourceMetadata,
            currentRevisionID: revisionID,
            updatedAt: date,
            modifiedByDeviceID: "Mac"
        )
        let revision = EntryRevisionRecord(
            id: revisionID,
            entryID: entryID,
            parentRevisionID: nil,
            snapshot: draft,
            createdAt: date,
            deviceID: "Mac"
        )
        let attachment = AttachmentRecord(
            entryID: entryID,
            originalName: "cover.jpg",
            mimeType: "image/jpeg",
            checksum: "abc123",
            byteCount: 42,
            state: .pending,
            updatedAt: date
        )
        let rule = ClassificationRuleRecord(
            source: .tag,
            value: "독서",
            targetKind: .reading,
            priority: 20,
            updatedAt: date
        )
        let epoch = RestoreEpochRecord(createdAt: date, mode: .replace)

        try assertJSONRoundTrip(entry)
        try assertJSONRoundTrip(revision)
        try assertJSONRoundTrip(attachment)
        try assertJSONRoundTrip(rule)
        try assertJSONRoundTrip(epoch)
    }

    func testVersionedSchemaDiskReopenAndSourceSnapshotIsolation() throws {
        XCTAssertEqual(
            PilgrimJournalSchemaV1.versionIdentifier,
            Schema.Version(1, 0, 0)
        )
        XCTAssertEqual(PilgrimJournalMigrationPlan.schemas.count, 1)
        XCTAssertTrue(PilgrimJournalMigrationPlan.stages.isEmpty)

        let canonicalTypes = Set(
            PilgrimJournalSchemaV1.canonicalModels.map(ObjectIdentifier.init)
        )
        let localTypes = Set(
            PilgrimJournalSchemaV1.localModels.map(ObjectIdentifier.init)
        )
        XCTAssertFalse(canonicalTypes.contains(ObjectIdentifier(SourceSnapshotEntity.self)))
        XCTAssertTrue(localTypes.contains(ObjectIdentifier(SourceSnapshotEntity.self)))

        let directory = FileManager.default.temporaryDirectory.appending(
            path: "PilgrimJournalSchema-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let entryID: UUID
        let rawSnapshot = Data("{\"private\":\"mac-only\"}".utf8)

        do {
            let container = try JournalContainerFactory.make(
                storageDirectory: directory
            )
            XCTAssertNotNil(container.migrationPlan)
            XCTAssertEqual(container.schema.version, Schema.Version(1, 0, 0))

            let repository = SwiftDataJournalRepository(container: container)
            entryID = try repository.save(
                JournalEntryDraft(kind: .diary, body: "재개방 확인"),
                deviceID: "Mac"
            ).id

            let importStore = LocalImportStore(container: container)
            let jobID = try importStore.begin(
                fingerprint: "fixture-fingerprint",
                displayName: "fixture.zip",
                totalCount: 1
            )
            try importStore.record(
                jobID: jobID,
                item: ImportAuditItem(
                    sourceUUID: "source-1",
                    entryID: entryID,
                    status: .imported
                ),
                rawJSON: rawSnapshot
            )
        }

        do {
            let reopened = try JournalContainerFactory.make(
                storageDirectory: directory
            )
            let repository = SwiftDataJournalRepository(container: reopened)
            XCTAssertEqual(try repository.entry(id: entryID)?.body, "재개방 확인")

            let context = ModelContext(reopened)
            let snapshots = try context.fetch(FetchDescriptor<SourceSnapshotEntity>())
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(snapshots.first?.rawJSON, rawSnapshot)

            let localConfiguration = try XCTUnwrap(
                reopened.configurations.first { $0.name == "LocalAuxiliary" }
            )
            XCTAssertNil(localConfiguration.cloudKitContainerIdentifier)
        }
    }

    func testStoreChangeExtractorRoutesCanonicalIDsAndIgnoresLocalSnapshots() throws {
        let container = try JournalContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let entryID = UUID()

        let entry = JournalEntryEntity()
        entry.stableID = entryID
        context.insert(entry)
        context.processPendingChanges()
        let entryNotification = Notification(
            name: ModelContext.didSave,
            object: context,
            userInfo: [
                ModelContext.NotificationKey.insertedIdentifiers:
                    Set([entry.persistentModelID]),
            ]
        )
        let change = try XCTUnwrap(
            JournalStoreChangeExtractor.extract(from: entryNotification)
        )
        XCTAssertEqual(change.entryIDs, [entryID])
        XCTAssertFalse(change.requiresFullRefresh)

        let snapshot = SourceSnapshotEntity()
        context.insert(snapshot)
        context.processPendingChanges()
        let snapshotNotification = Notification(
            name: ModelContext.didSave,
            object: context,
            userInfo: [
                ModelContext.NotificationKey.insertedIdentifiers:
                    Set([snapshot.persistentModelID]),
            ]
        )
        XCTAssertNil(JournalStoreChangeExtractor.extract(from: snapshotNotification))
    }

    func testTimelineCursorKeepsStableNewestFirstOrderAndKindFilter() throws {
        let repository = try makeRepository()
        let identifiers = [
            UUID(uuidString: "10000000-0000-4000-8000-000000000000")!,
            UUID(uuidString: "20000000-0000-4000-8000-000000000000")!,
            UUID(uuidString: "30000000-0000-4000-8000-000000000000")!,
            UUID(uuidString: "40000000-0000-4000-8000-000000000000")!,
        ]
        let dates: [TimeInterval] = [300, 200, 200, 100]
        for (id, timestamp) in zip(identifiers, dates) {
            _ = try repository.save(
                JournalEntryDraft(
                    id: id,
                    kind: .diary,
                    body: id.uuidString,
                    occurredAt: Date(timeIntervalSince1970: timestamp)
                ),
                deviceID: "Mac"
            )
        }
        _ = try repository.save(
            JournalEntryDraft(
                kind: .prayer,
                body: "다른 유형",
                occurredAt: Date(timeIntervalSince1970: 400)
            ),
            deviceID: "Mac"
        )

        let first = try repository.page(
            kind: .diary,
            includeDeleted: false,
            after: nil,
            limit: 2
        )
        XCTAssertEqual(first.entries.map(\.id), Array(identifiers.prefix(2)))
        let cursor = try XCTUnwrap(first.nextCursor)

        let second = try repository.page(
            kind: .diary,
            includeDeleted: false,
            after: cursor,
            limit: 2
        )
        XCTAssertEqual(second.entries.map(\.id), Array(identifiers.suffix(2)))
        XCTAssertNil(second.nextCursor)
    }

    @MainActor
    func testBatchOrganizationChangesKindAddsUniqueTagsAndCreatesRevisions() throws {
        let repository = InMemoryJournalRepository()
        let first = try repository.save(
            JournalEntryDraft(
                kind: .prayer,
                body: "첫 기록",
                tags: ["기존"],
                details: EntryDetails(prayerStatus: .ongoing)
            ),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        let second = try repository.save(
            JournalEntryDraft(
                kind: .bibleStudy,
                body: "둘째 기록",
                tags: ["공통"]
            ),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 20)
        )

        let result = try JournalBatchOrganizer().apply(
            entryIDs: [first.id, second.id],
            targetKind: .diary,
            addingTags: ["공통", " 정리 ", "정리"],
            repository: repository,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(result.updatedCount, 2)
        for id in [first.id, second.id] {
            let updated = try XCTUnwrap(repository.entry(id: id))
            XCTAssertEqual(updated.kind, .diary)
            XCTAssertTrue(updated.tags.contains("정리"))
            XCTAssertEqual(updated.tags.filter { $0 == "정리" }.count, 1)
            XCTAssertEqual(try repository.revisions(entryID: id).count, 2)
            XCTAssertEqual(updated.modifiedByDeviceID, "iPhone")
        }
        XCTAssertNil(try repository.entry(id: first.id)?.details.prayerStatus)
    }

    func testRenameAndRemoveTagUpdatesEveryRecordWithoutDeletingEntries() throws {
        let repository = InMemoryJournalRepository()
        let first = try repository.save(
            JournalEntryDraft(kind: .diary, body: "첫 기록", tags: ["여행", "공통"]),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        let second = try repository.save(
            JournalEntryDraft(kind: .reading, body: "둘째 기록", tags: ["여행"]),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 20)
        )

        let renamed = try JournalTagManager().rename(
            tag: " 여행 ",
            to: "순례",
            repository: repository,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(renamed.count, 2)
        XCTAssertTrue(renamed.allSatisfy { $0.tags.contains("순례") })
        XCTAssertTrue(renamed.allSatisfy { !$0.tags.contains("여행") })

        let removed = try JournalTagManager().remove(
            tag: "순례",
            repository: repository,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(
            try repository.list(kind: nil, includeDeleted: false, limit: 10).count,
            2
        )
        XCTAssertEqual(try repository.revisions(entryID: first.id).count, 3)
        XCTAssertEqual(try repository.revisions(entryID: second.id).count, 3)
        XCTAssertFalse(removed.contains { $0.tags.contains("순례") })
    }

    private func assertJSONRoundTrip<T>(_ value: T) throws
    where T: Codable & Equatable {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: encoded)
        let matches = decoded == value
        XCTAssertTrue(matches)
    }
}
#endif
