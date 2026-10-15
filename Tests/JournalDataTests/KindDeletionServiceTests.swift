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

    private func deleted(_ kind: JournalKind, to target: JournalKind) throws -> KindCatalog {
        var catalog = KindCatalog()
        try catalog.delete(kind, moveTarget: target, deviceID: "d", at: t1)
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

        let moved = try KindDeletionService().moveEntries(
            from: .prayer, to: .diary, repository: repository, deviceID: "d2", at: t1)

        XCTAssertEqual(moved.count, 1)
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
        let moved = try KindDeletionService().moveEntries(
            from: .prayer, to: .memo, repository: repository, deviceID: "d", at: t1)
        XCTAssertTrue(moved.isEmpty)
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
        let count = try KindDeletionService().retargetRules(
            from: .prayer, to: .diary, repository: repository, at: t1)
        XCTAssertEqual(count, 2)
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

        let moved = try KindReconciler().reconcile(
            catalog: try deleted(.prayer, to: .memo), repository: repository,
            deviceID: "d", at: t2)

        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(try repository.entry(id: prayer.id)?.kind, .memo)
        XCTAssertEqual(try repository.entry(id: other.id), other)
        XCTAssertEqual(try repository.entry(id: diary.id), diary)
    }

    func testReconcilerIsNoOpWithoutDeletedKinds() throws {
        let repository = InMemoryJournalRepository()
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "p"), deviceID: "d", at: t0)
        let moved = try KindReconciler().reconcile(
            catalog: KindCatalog(), repository: repository, deviceID: "d", at: t2)
        XCTAssertTrue(moved.isEmpty)
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
        let moved = try KindDeletionService().moveEntries(
            from: .diary, to: .unclassified, repository: repository, deviceID: "d", at: t1)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .unclassified)
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
#endif
