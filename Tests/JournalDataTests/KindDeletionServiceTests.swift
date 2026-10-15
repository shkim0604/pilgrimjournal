#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import XCTest

@MainActor
final class KindDeletionServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_100_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_200_000)

    private func deleted(
        _ kind: JournalKind, to target: JournalKind, by deviceID: String = "d"
    ) throws -> KindCatalog {
        var catalog = KindCatalog()
        try catalog.delete(kind, moveTarget: target, deviceID: deviceID, at: t1)
        return catalog
    }

    func testBodyAppendingCarryOver() {
        XCTAssertEqual(
            KindDeletionService.body("본문", appending: "기분: 평안"), "본문\n\n---\n기분: 평안")
        XCTAssertEqual(KindDeletionService.body("", appending: "기분: 평안"), "기분: 평안")
        XCTAssertEqual(KindDeletionService.body("  \n", appending: "기분: 평안"), "기분: 평안")
        XCTAssertEqual(KindDeletionService.body("본문", appending: nil), "본문")
    }

    func testMovePrayerEntriesToDiaryAppendsDetailsAndKeepsRevision() throws {
        let repository = InMemoryJournalRepository()
        let prayer = try repository.save(
            JournalEntryDraft(
                kind: .prayer, body: "감사",
                originalTimeZone: "Asia/Seoul",
                details: EntryDetails(prayerStatus: .answered, answeredAt: t0)),
            deviceID: "d", at: t0)
        let diary = try repository.save(
            JournalEntryDraft(kind: .diary, body: "오늘"), deviceID: "d", at: t0)

        let outcome = try KindDeletionService().moveEntries(
            from: .prayer, to: .diary, repository: repository, deviceID: "d2", at: t1)

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertNil(outcome.error)
        let after = try XCTUnwrap(repository.entry(id: prayer.id))
        XCTAssertEqual(after.kind, .diary)
        XCTAssertTrue(after.body.hasPrefix("감사\n\n---\n기도 상태: 응답됨 ("))
        XCTAssertEqual(after.details, EntryDetails())
        let revisions = try repository.revisions(entryID: prayer.id)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertTrue(revisions.contains { $0.snapshot.kind == .prayer })
        XCTAssertEqual(try repository.entry(id: diary.id), diary)
    }

    func testMoveSkipsTrashedEntries() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "a"), deviceID: "d", at: t0)
        try repository.moveToTrash(entryID: entry.id, deviceID: "d", at: t0)
        let outcome = try KindDeletionService().moveEntries(
            from: .prayer, to: .memo, repository: repository, deviceID: "d", at: t1)
        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .prayer)
    }

    func testRetargetRules() throws {
        let repository = InMemoryJournalRepository()
        for value in ["a", "b"] {
            try repository.saveClassificationRule(
                ClassificationRuleRecord(
                    source: .tag, value: value, targetKind: .prayer, updatedAt: t0))
        }
        try repository.saveClassificationRule(
            ClassificationRuleRecord(source: .tag, value: "c", targetKind: .memo, updatedAt: t0))
        let outcome = try KindDeletionService().retargetRules(
            from: .prayer, to: .diary, repository: repository, at: t1)
        XCTAssertEqual(outcome.retargetedRuleCount, 2)
        XCTAssertNil(outcome.error)
        let rules = try repository.classificationRules()
        XCTAssertEqual(rules.filter { $0.targetKind == .diary }.count, 2)
        XCTAssertEqual(rules.filter { $0.targetKind == .memo }.count, 1)
        XCTAssertTrue(rules.filter { $0.targetKind == .diary }.allSatisfy { $0.updatedAt == t1 })
    }

    func testReconcilerMovesOnlyDeletedKindsAndLeavesUnknownIds() throws {
        let repository = InMemoryJournalRepository()
        let unknown = JournalKind(id: "custom-UNKNOWN")
        let prayer = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "p"), deviceID: "d", at: t0)
        let other = try repository.save(
            JournalEntryDraft(kind: unknown, body: "u"), deviceID: "d", at: t0)
        let diary = try repository.save(
            JournalEntryDraft(kind: .diary, body: "d"), deviceID: "d", at: t0)

        let outcome = try KindReconciler().reconcile(
            catalog: try deleted(.prayer, to: .memo), repository: repository,
            deviceID: "d", at: t2)

        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertEqual(try repository.entry(id: prayer.id)?.kind, .memo)
        XCTAssertEqual(try repository.entry(id: other.id), other)
        XCTAssertEqual(try repository.entry(id: diary.id), diary)
    }

    func testReconcilerIsNoOpWithoutDeletedKinds() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "p"), deviceID: "d", at: t0)
        let outcome = try KindReconciler().reconcile(
            catalog: KindCatalog(), repository: repository, deviceID: "d", at: t2)
        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(try repository.revisions(entryID: entry.id).count, 1)
    }

    func testReconcilerMovesEntrySavedWithDeletedKindAfterDeletion() throws {
        let repository = InMemoryJournalRepository()
        let catalog = try deleted(.prayer, to: .memo)
        _ = try KindDeletionService().moveEntries(
            from: .prayer, to: .memo, repository: repository, deviceID: "d", at: t1)
        let late = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "late"), deviceID: "other", at: t2)
        _ = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "d", at: t2)
        XCTAssertEqual(try repository.entry(id: late.id)?.kind, .memo)
    }

    func testTrashedEntryIsMovedAfterItIsRestored() throws {
        let repository = InMemoryJournalRepository()
        let catalog = try deleted(.prayer, to: .memo)
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "p"), deviceID: "d", at: t0)
        try repository.moveToTrash(entryID: entry.id, deviceID: "d", at: t0)
        _ = try KindDeletionService().moveEntries(
            from: .prayer, to: .memo, repository: repository, deviceID: "d", at: t1)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .prayer)

        try repository.restoreFromTrash(entryID: entry.id, deviceID: "d", at: t1)
        _ = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "d", at: t2)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .memo)
    }

    func testMoveManualEntriesToUnclassified() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .diary, body: "d"), deviceID: "d", at: t0)
        let outcome = try KindDeletionService().moveEntries(
            from: .diary, to: .unclassified, repository: repository, deviceID: "d", at: t1)
        XCTAssertEqual(outcome.moved.count, 1)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .unclassified)
    }

    /// Restore and scope migration save entries missing from the store with
    /// their `id` set; only a draft without an `id` is a new manual entry.
    func testInMemoryManualUnclassifiedDraftWithIDIsAcceptedEvenWhenAbsent() throws {
        let repository = InMemoryJournalRepository()
        let id = UUID()
        let saved = try repository.save(
            JournalEntryDraft(id: id, kind: .unclassified, body: "옮겨진 기록"),
            deviceID: "d", at: t0)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(try repository.entry(id: id)?.kind, .unclassified)
        XCTAssertThrowsError(
            try repository.save(
                JournalEntryDraft(kind: .unclassified, body: "새 기록"), deviceID: "d", at: t0)
        ) { XCTAssertEqual($0 as? JournalError, .invalidManualKind) }
    }

    // MARK: Cross-device staleness (another device deleted the kind)

    /// Device "A" edited the entry, then deleted 기도노트 and moved it. This
    /// device still holds A's pre-deletion copy because CloudKit has not
    /// delivered the moved one yet; moving that stale copy with a later stamp
    /// would overwrite A's newer version, so the reconciler waits instead.
    func testReconcilerLeavesDeletingDevicesPreDeletionCopyForCloudKit() throws {
        let repository = InMemoryJournalRepository()
        let catalog = try deleted(.prayer, to: .memo, by: "A")
        let stale = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "A가 고치기 전"), deviceID: "A", at: t0)
        let atDeletion = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "삭제와 같은 시각"), deviceID: "A", at: t1)
        let byOther = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "B가 쓴 기록"), deviceID: "B", at: t0)
        let afterStamp = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "A가 나중에 쓴 기록"), deviceID: "A", at: t2)

        let outcome = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "B", at: t2)

        XCTAssertEqual(try repository.entry(id: stale.id), stale)
        XCTAssertEqual(try repository.entry(id: atDeletion.id), atDeletion)
        XCTAssertEqual(try repository.entry(id: byOther.id)?.kind, .memo)
        XCTAssertEqual(try repository.entry(id: afterStamp.id)?.kind, .memo)
        XCTAssertEqual(Set(outcome.moved.map(\.id)), [byOther.id, afterStamp.id])
    }

    /// On the deleting device itself nothing newer is on its way, so an entry
    /// its own move pass missed (e.g. a failed save) is retried.
    func testReconcilerOnDeletingDeviceRetriesItsOwnUnmovedEntries() throws {
        let repository = InMemoryJournalRepository()
        let catalog = try deleted(.prayer, to: .memo, by: "A")
        let missed = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "옮기지 못한 기록"), deviceID: "A", at: t0)

        _ = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "A", at: t2)

        XCTAssertEqual(try repository.entry(id: missed.id)?.kind, .memo)
    }

    /// The skip compares against the definition of the entry's own kind,
    /// not the end of its move chain.
    func testReconcilerUsesTheEntrysOwnKindDefinitionForTheSkip() throws {
        let repository = InMemoryJournalRepository()
        var catalog = KindCatalog()
        try catalog.delete(.prayer, moveTarget: .reading, deviceID: "A", at: t1)
        try catalog.delete(.reading, moveTarget: .memo, deviceID: "C", at: t1)
        // A deleted 기도노트, so A's own pre-deletion copy waits for CloudKit…
        let byA = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "A"), deviceID: "A", at: t0)
        // …while C only deleted 독서노트, which says nothing about 기도노트 entries.
        let byC = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "C"), deviceID: "C", at: t0)

        _ = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "B", at: t2)

        XCTAssertEqual(try repository.entry(id: byA.id), byA)
        XCTAssertEqual(try repository.entry(id: byC.id)?.kind, .memo)
    }

    // MARK: 미분류 is never a deleted kind

    func testReconcilerNeverRewritesUnclassifiedEvenIfCatalogSaysDeleted() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(id: UUID(), kind: .unclassified, body: "u"), deviceID: "d", at: t0)
        try repository.saveClassificationRule(
            ClassificationRuleRecord(
                source: .tag, value: "x", targetKind: .unclassified, updatedAt: t0))
        var unclassified = KindCatalog.defaultDefinition(for: .unclassified)
        unclassified.state = .deleted(moveTarget: .memo)
        unclassified.updatedAt = t1
        unclassified.modifiedByDeviceID = "other"
        let catalog = KindCatalog(definitions: [unclassified])

        let outcome = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "d", at: t2)

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(try repository.entry(id: entry.id), entry)
        XCTAssertEqual(try repository.revisions(entryID: entry.id).count, 1)
        XCTAssertEqual(try repository.classificationRules().map(\.targetKind), [.unclassified])
    }

    // MARK: One unsaveable entry does not block the rest

    func testMoveEntriesSkipsAnUnsaveableEntryAndMovesTheRest() throws {
        let base = InMemoryJournalRepository()
        let first = try base.save(
            JournalEntryDraft(kind: .prayer, body: "1"), deviceID: "d", at: t0)
        let broken = try base.save(
            JournalEntryDraft(kind: .prayer, body: "2"), deviceID: "d", at: t0)
        let third = try base.save(
            JournalEntryDraft(kind: .prayer, body: "3"), deviceID: "d", at: t0)
        let repository = FailingSaveRepository(base: base, failingEntryIDs: [broken.id])

        let outcome = try KindDeletionService().moveEntries(
            from: .prayer, to: .memo, repository: repository, deviceID: "d", at: t1)

        XCTAssertEqual(Set(outcome.moved.map(\.id)), [first.id, third.id])
        XCTAssertEqual(outcome.failures.map(\.id), [broken.id])
        let error = try XCTUnwrap(outcome.error)
        XCTAssertTrue(error.errorDescription?.contains("기록 1개") == true)
        XCTAssertEqual(try base.entry(id: first.id)?.kind, .memo)
        XCTAssertEqual(try base.entry(id: broken.id)?.kind, .prayer)
        XCTAssertEqual(try base.entry(id: third.id)?.kind, .memo)
    }

    func testReconcilerSkipsAnUnsaveableEntryAndStillRetargetsRules() throws {
        let base = InMemoryJournalRepository()
        let broken = try base.save(
            JournalEntryDraft(kind: .prayer, body: "2"), deviceID: "d", at: t0)
        let fine = try base.save(
            JournalEntryDraft(kind: .prayer, body: "1"), deviceID: "d", at: t0)
        try base.saveClassificationRule(
            ClassificationRuleRecord(source: .tag, value: "x", targetKind: .prayer, updatedAt: t0))
        let repository = FailingSaveRepository(base: base, failingEntryIDs: [broken.id])

        let outcome = try KindReconciler().reconcile(
            catalog: try deleted(.prayer, to: .memo), repository: repository,
            deviceID: "d", at: t2)

        XCTAssertEqual(outcome.moved.map(\.id), [fine.id])
        XCTAssertEqual(outcome.failures.map(\.id), [broken.id])
        XCTAssertNotNil(outcome.error)
        XCTAssertEqual(try base.classificationRules().map(\.targetKind), [.memo])
    }

    func testReconcilerMovesToUnclassifiedOnCycle() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "p"), deviceID: "d", at: t0)
        var catalog = KindCatalog()
        try catalog.delete(.prayer, moveTarget: .reading, deviceID: "d", at: t1)
        try catalog.delete(.reading, moveTarget: .diary, deviceID: "d", at: t1)
        var reading = catalog.definition(for: .reading)
        reading.state = .deleted(moveTarget: .prayer)
        catalog = KindCatalog(
            definitions: catalog.definitions.map {
                $0.kind == .reading ? reading : $0
            })
        _ = try KindReconciler().reconcile(
            catalog: catalog, repository: repository, deviceID: "d", at: t2)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .unclassified)
    }
}
/// Forwards to an in-memory repository but refuses to save chosen entries.
@MainActor
private final class FailingSaveRepository: JournalRepository {
    let base: InMemoryJournalRepository
    let failingEntryIDs: Set<UUID>

    init(base: InMemoryJournalRepository, failingEntryIDs: Set<UUID>) {
        self.base = base
        self.failingEntryIDs = failingEntryIDs
    }

    func list(kind: JournalKind?, includeDeleted: Bool, limit: Int) throws -> [JournalEntryRecord] {
        try base.list(kind: kind, includeDeleted: includeDeleted, limit: limit)
    }

    func page(
        kind: JournalKind?, includeDeleted: Bool, after cursor: JournalTimelineCursor?, limit: Int
    ) throws -> JournalTimelinePage {
        try base.page(kind: kind, includeDeleted: includeDeleted, after: cursor, limit: limit)
    }

    func entry(id: UUID) throws -> JournalEntryRecord? { try base.entry(id: id) }

    func entry(sourceUUID: String) throws -> JournalEntryRecord? {
        try base.entry(sourceUUID: sourceUUID)
    }

    func save(_ draft: JournalEntryDraft, deviceID: String, at date: Date) throws
        -> JournalEntryRecord
    {
        if let id = draft.id, failingEntryIDs.contains(id) {
            throw JournalError.persistence("저장 실패")
        }
        return try base.save(draft, deviceID: deviceID, at: date)
    }

    func revisions(entryID: UUID) throws -> [EntryRevisionRecord] {
        try base.revisions(entryID: entryID)
    }

    func restore(entryID: UUID, revisionID: UUID, deviceID: String, at date: Date) throws
        -> JournalEntryRecord
    {
        try base.restore(entryID: entryID, revisionID: revisionID, deviceID: deviceID, at: date)
    }

    func moveToTrash(entryID: UUID, deviceID: String, at date: Date) throws {
        try base.moveToTrash(entryID: entryID, deviceID: deviceID, at: date)
    }

    func restoreFromTrash(entryID: UUID, deviceID: String, at date: Date) throws {
        try base.restoreFromTrash(entryID: entryID, deviceID: deviceID, at: date)
    }

    func purgeEntries(ids: Set<UUID>) throws -> JournalPurgeSummary {
        try base.purgeEntries(ids: ids)
    }

    func classificationRules() throws -> [ClassificationRuleRecord] {
        try base.classificationRules()
    }

    func saveClassificationRule(_ rule: ClassificationRuleRecord) throws {
        try base.saveClassificationRule(rule)
    }

    func deleteClassificationRule(id: UUID) throws {
        try base.deleteClassificationRule(id: id)
    }
}
#endif
