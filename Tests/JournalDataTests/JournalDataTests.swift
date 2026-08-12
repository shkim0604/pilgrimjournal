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

    func testSourceUUIDLookupFindsEntriesPastFiveHundred() throws {
        let repository = try makeRepository()
        for index in 0..<520 {
            _ = try repository.save(
                JournalEntryDraft(
                    kind: .diary,
                    body: "가져온 본문 \(index)",
                    sourceUUID: "DAY-ONE-\(index)"
                ),
                deviceID: "Mac",
                at: .now
            )
        }
        XCTAssertNotNil(try repository.entry(sourceUUID: "DAY-ONE-0"))
        XCTAssertNotNil(try repository.entry(sourceUUID: "day-one-519"))
        XCTAssertThrowsError(
            try repository.save(
                JournalEntryDraft(
                    kind: .diary,
                    body: "중복",
                    sourceUUID: "DAY-ONE-519"
                ),
                deviceID: "Mac",
                at: .now
            )
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

    func testIndependentOfflineEditsFromDifferentDevicesAreBothPreserved() throws {
        let repository = try makeRepository()
        let macEntry = try repository.save(
            JournalEntryDraft(kind: .memo, title: "Mac 기록"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        let phoneEntry = try repository.save(
            JournalEntryDraft(kind: .memo, title: "iPhone 기록"),
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 10)
        )

        var macEdit = macEntry.draft
        macEdit.body = "Mac 오프라인 편집"
        var phoneEdit = phoneEntry.draft
        phoneEdit.body = "iPhone 오프라인 편집"
        _ = try repository.save(
            macEdit,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 20)
        )
        _ = try repository.save(
            phoneEdit,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(try repository.entry(id: macEntry.id)?.body, "Mac 오프라인 편집")
        XCTAssertEqual(try repository.entry(id: phoneEntry.id)?.body, "iPhone 오프라인 편집")
        XCTAssertEqual(try repository.revisions(entryID: macEntry.id).count, 2)
        XCTAssertEqual(try repository.revisions(entryID: phoneEntry.id).count, 2)
    }

    func testConcurrentSiblingRevisionsAreBothKeptAndResolveDeterministically() throws {
        let repository = try makeRepository()
        let base = try repository.save(
            JournalEntryDraft(kind: .diary, title: "공통 원본"),
            deviceID: "seed",
            at: Date(timeIntervalSince1970: 10)
        )
        var macDraft = base.draft
        macDraft.body = "Mac 편집"
        var phoneDraft = base.draft
        phoneDraft.body = "iPhone 편집"
        let macRevision = EntryRevisionRecord(
            entryID: base.id,
            parentRevisionID: base.currentRevisionID,
            snapshot: macDraft,
            createdAt: Date(timeIntervalSince1970: 20),
            deviceID: "Mac"
        )
        let phoneRevision = EntryRevisionRecord(
            entryID: base.id,
            parentRevisionID: base.currentRevisionID,
            snapshot: phoneDraft,
            createdAt: Date(timeIntervalSince1970: 20),
            deviceID: "iPhone"
        )

        try repository.importRevision(macRevision)
        try repository.importRevision(phoneRevision)

        let revisions = try repository.revisions(entryID: base.id)
        XCTAssertTrue(revisions.contains(macRevision))
        XCTAssertTrue(revisions.contains(phoneRevision))
        let resolver = RevisionResolver()
        XCTAssertEqual(
            resolver.winner(macRevision, phoneRevision),
            resolver.winner(phoneRevision, macRevision)
        )
        XCTAssertEqual(
            resolver.winner(macRevision, phoneRevision).deviceID,
            "iPhone"
        )
    }

    func testTombstoneRejectsOldEditUntilExplicitRestore() throws {
        let repository = try makeRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .diary, title: "삭제 대상"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        try repository.moveToTrash(
            entryID: record.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 30)
        )

        var stalePhoneEdit = record.draft
        stalePhoneEdit.body = "오래된 iPhone 편집"
        _ = try repository.save(
            stalePhoneEdit,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 20)
        )

        XCTAssertTrue(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)
        XCTAssertTrue(try repository.list(kind: nil, includeDeleted: false, limit: 10).isEmpty)
        XCTAssertTrue(
            try repository.revisions(entryID: record.id).contains {
                $0.snapshot.body == "오래된 iPhone 편집"
            }
        )

        try repository.restoreFromTrash(
            entryID: record.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 40)
        )
        let restored = try XCTUnwrap(repository.entry(id: record.id))
        XCTAssertFalse(restored.isDeleted)
        XCTAssertEqual(restored.body, "오래된 iPhone 편집")
        XCTAssertEqual(try repository.revisions(entryID: record.id).count, 3)
    }

    func testInMemoryTombstoneAlsoRequiresExplicitRestore() throws {
        let repository = InMemoryJournalRepository()
        let record = try repository.save(
            JournalEntryDraft(kind: .memo, title: "삭제 대상"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        try repository.moveToTrash(
            entryID: record.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 30)
        )
        var staleDraft = record.draft
        staleDraft.body = "오래된 편집"
        _ = try repository.save(
            staleDraft,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 20)
        )
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)

        try repository.restoreFromTrash(
            entryID: record.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 40)
        )
        XCTAssertFalse(try XCTUnwrap(repository.entry(id: record.id)).isDeleted)
    }

    func testSwiftDataRestoreTransactionRollsBackUncommittedChanges() throws {
        enum ExpectedFailure: Error { case stop }
        let repository = try makeRepository()
        let original = try repository.save(
            JournalEntryDraft(kind: .memo, title: "원본"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 1)
        )
        let addedID = UUID()

        XCTAssertThrowsError(try repository.performRestoreTransaction {
            try repository.moveToTrash(
                entryID: original.id,
                deviceID: "restore",
                at: Date(timeIntervalSince1970: 2)
            )
            _ = try repository.save(
                JournalEntryDraft(id: addedID, kind: .memo, title: "복원 중 추가"),
                deviceID: "restore",
                at: Date(timeIntervalSince1970: 2)
            )
            throw ExpectedFailure.stop
        })

        XCTAssertFalse(try XCTUnwrap(repository.entry(id: original.id)).isDeleted)
        XCTAssertNil(try repository.entry(id: addedID))
        XCTAssertEqual(try repository.revisions(entryID: original.id).count, 1)
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

    func testClassificationRuleReplicasConvergeAcrossOppositeDeliveryOrders() throws {
        let identifier = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let date = Date(timeIntervalSince1970: 100)
        let firstEdit = ClassificationRuleRecord(
            id: identifier,
            source: .templateTitle,
            value: "아침 묵상",
            targetKind: .prayer,
            priority: 20,
            updatedAt: date
        )
        let secondEdit = ClassificationRuleRecord(
            id: identifier,
            source: .templateTitle,
            value: "아침 묵상",
            targetKind: .bibleStudy,
            priority: 20,
            updatedAt: date
        )
        let macReplica = InMemoryJournalRepository()
        let phoneReplica = InMemoryJournalRepository()

        try macReplica.saveClassificationRule(firstEdit)
        try macReplica.saveClassificationRule(secondEdit)
        try phoneReplica.saveClassificationRule(secondEdit)
        try phoneReplica.saveClassificationRule(firstEdit)

        let macRules = try macReplica.classificationRules()
        let phoneRules = try phoneReplica.classificationRules()
        XCTAssertEqual(macRules, phoneRules)
        XCTAssertEqual(macRules.count, 1)
        XCTAssertTrue(
            PilgrimJournalSchemaV1.canonicalModels.contains {
                ObjectIdentifier($0) == ObjectIdentifier(ClassificationRuleEntity.self)
            }
        )
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

    func testAttachmentChecksumDeduplicationAndReferenceAwareDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-attachment-dedup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentFileStore(root: root)
        let binary = Data("same binary".utf8)
        let first = try store.store(
            data: binary,
            entryID: UUID(),
            originalName: "first.bin",
            mimeType: "application/octet-stream"
        )
        let second = try store.store(
            data: binary,
            entryID: UUID(),
            originalName: "second.bin",
            mimeType: "application/octet-stream"
        )

        XCTAssertEqual(first.record.checksum, second.record.checksum)
        XCTAssertFalse(first.wasDeduplicated)
        XCTAssertTrue(second.wasDeduplicated)
        try store.removeIfUnreferenced(
            checksum: first.record.checksum,
            referencedChecksums: [second.record.checksum]
        )
        XCTAssertEqual(try store.data(checksum: first.record.checksum), binary)

        try store.removeIfUnreferenced(
            checksum: first.record.checksum,
            referencedChecksums: []
        )
        XCTAssertThrowsError(try store.data(checksum: first.record.checksum))
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

    func testFiveThousandEntryPaginationIsCompleteAndResponsive() throws {
        let repository = InMemoryJournalRepository()
        for value in 0..<5_000 {
            _ = try repository.save(
                JournalEntryDraft(
                    kind: .memo,
                    title: "합성 기록 \(value)",
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(value))
                ),
                deviceID: "performance-test",
                at: Date(timeIntervalSince1970: TimeInterval(value))
            )
        }

        let started = ContinuousClock.now
        var cursor: JournalTimelineCursor?
        var identifiers = Set<UUID>()
        repeat {
            let page = try repository.page(
                kind: .memo,
                includeDeleted: false,
                after: cursor,
                limit: 200
            )
            identifiers.formUnion(page.entries.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        let duration = started.duration(to: .now)

        XCTAssertEqual(identifiers.count, 5_000)
        XCTAssertLessThan(duration, .seconds(3))
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

    func testAccountScopesDoNotExposeRawIdentifiersAndUseDistinctDirectories() throws {
        let local = JournalAccountScope(
            appleUserIdentifier: "apple-user@example.com",
            storageLocation: .localOnly
        )
        let sameUser = JournalAccountScope(
            appleUserIdentifier: "apple-user@example.com",
            storageLocation: .iCloud(accountHash: "icloud-a")
        )
        let otherUser = JournalAccountScope(
            appleUserIdentifier: "other-user@example.com",
            storageLocation: .localOnly
        )

        XCTAssertEqual(local.appleUserHash, sameUser.appleUserHash)
        XCTAssertNotEqual(local.appleUserHash, otherUser.appleUserHash)
        XCTAssertNotEqual(local.relativeDirectory, sameUser.relativeDirectory)
        XCTAssertFalse(local.relativeDirectory.contains("apple-user@example.com"))
    }

    func testScopeRegistrySeparatesStoresAndRejectsAChangedAppleUser() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "account-scope-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = JournalAccountScopeRegistry(root: root)
        let first = JournalAccountScope(
            appleUserIdentifier: "first-user",
            storageLocation: .localOnly
        )
        let cloud = JournalAccountScope(
            appleUserHash: first.appleUserHash,
            storageLocation: .iCloud(accountHash: "cloud-account")
        )
        let second = JournalAccountScope(
            appleUserIdentifier: "second-user",
            storageLocation: .localOnly
        )

        let localPaths = try registry.prepareScope(first)
        let cloudPaths = try registry.prepareScope(cloud)
        XCTAssertNotEqual(localPaths.root, cloudPaths.root)
        XCTAssertNotEqual(localPaths.search, cloudPaths.search)

        try registry.claimLegacyData(for: first)
        XCTAssertThrowsError(try registry.verifyLegacyClaim(for: second)) { error in
            XCTAssertEqual(
                error as? JournalAccountScopeError,
                .legacyDataClaimedByDifferentUser
            )
        }
    }

    func testScopeMigrationPreservesIDsTombstonesRevisionsRulesAndAttachments() throws {
        let source = InMemoryJournalRepository()
        let destination = InMemoryJournalRepository()
        let original = try source.save(
            JournalEntryDraft(
                kind: .memo,
                title: "기존 기록",
                body: "첫 본문",
                sourceUUID: "legacy-entry"
            ),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        var edited = original.draft
        edited.body = "수정된 본문"
        let editedRecord = try source.save(
            edited,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 20)
        )
        try source.moveToTrash(
            entryID: editedRecord.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 30)
        )
        let rule = ClassificationRuleRecord(
            source: .tag,
            value: "기도",
            targetKind: .prayer,
            priority: 5
        )
        try source.saveClassificationRule(rule)
        let binary = Data([0x50, 0x4A])
        let attachment = AttachmentRecord(
            entryID: editedRecord.id,
            originalName: "photo.jpg",
            mimeType: "image/jpeg",
            checksum: "checksum",
            byteCount: Int64(binary.count),
            state: .uploaded
        )
        try source.saveAttachment(attachment, binary: binary)
        let originalRevisionIDs = Set(
            try source.revisions(entryID: editedRecord.id).map(\.id)
        )

        let result = try JournalScopeMigrationService().migrate(
            from: source,
            to: destination,
            at: Date(timeIntervalSince1970: 40)
        )

        let migrated = try XCTUnwrap(destination.entry(id: editedRecord.id))
        XCTAssertEqual(migrated.body, "수정된 본문")
        XCTAssertEqual(migrated.deletedAt, Date(timeIntervalSince1970: 30))
        XCTAssertTrue(
            originalRevisionIDs.isSubset(of: Set(
                try destination.revisions(entryID: editedRecord.id).map(\.id)
            ))
        )
        XCTAssertEqual(try destination.classificationRules(), [rule])
        let migratedAttachment = try XCTUnwrap(
            destination.allAttachments().first { $0.0.id == attachment.id }
        )
        XCTAssertEqual(migratedAttachment.0, attachment)
        XCTAssertEqual(migratedAttachment.1, binary)
        XCTAssertEqual(result.migratedEntries, 1)
        XCTAssertEqual(result.migratedRevisions, 2)
        XCTAssertEqual(result.migratedRules, 1)
        XCTAssertEqual(result.migratedAttachments, 1)
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
