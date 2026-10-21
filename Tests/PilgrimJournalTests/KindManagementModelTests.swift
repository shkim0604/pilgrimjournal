#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

@MainActor
private final class LockedFeatureAccess: FeatureAccess {
    var canManageKinds: Bool { false }
}

@MainActor
final class KindManagementModelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-kind-management-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pilgrim-kind-management-\(UUID().uuidString)")!
    }

    private func makeModel(
        defaults: UserDefaults? = nil,
        repository: any JournalRepository = InMemoryJournalRepository(),
        cloudAccountMonitor: CloudAccountMonitor? = nil,
        featureAccess: (any FeatureAccess)? = nil
    ) throws -> AppModel {
        let paths = JournalPaths(root: root.appending(path: UUID().uuidString))
        try paths.prepare()
        return try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(url: paths.search.appending(path: "index.sqlite")),
            paths: paths,
            cloudAccountMonitor: cloudAccountMonitor,
            notebookDefaults: defaults ?? makeDefaults(),
            featureAccess: featureAccess
        )
    }

    func testCreateKindAppearsInSidebarAndPersistsAcrossModels() throws {
        let defaults = makeDefaults()
        let model = try makeModel(defaults: defaults)

        let created = try model.createKind(name: "설교노트", colorToken: .teal, iconToken: "star")

        XCTAssertTrue(model.sidebarKinds.contains { $0.kind == created && $0.name == "설교노트" })
        XCTAssertEqual(model.sidebarKinds.last?.kind, .unclassified)
        let second = try makeModel(defaults: defaults)
        XCTAssertTrue(second.kindCatalog.creatableKinds.contains { $0.name == "설교노트" })
        XCTAssertEqual(second.sidebarKinds.last?.kind, .unclassified)
    }

    func testDeleteKindMovesEntriesUpdatesSearchAndClearsSelection() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let first = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "평안을 구하는 기도"), deviceID: "d", at: .now)
        _ = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "감사의 기도"), deviceID: "d", at: .now)
        model.selectKind(.prayer)

        try model.deleteKind(.prayer, moveTo: .memo)

        XCTAssertNil(model.selectedKind)
        XCTAssertEqual(
            try repository.list(kind: .memo, includeDeleted: false, limit: 100).count, 2)
        let hits = try model.searchIndex.search(JournalSearchQuery(text: "평안을", kind: .memo))
        XCTAssertEqual(hits.map(\.id), [first.id])
        XCTAssertFalse(model.kindCatalog.activeKinds.contains { $0.kind == .prayer })
        XCTAssertEqual(model.kindCatalog.deletedBuiltIns.map(\.kind), [.prayer])
    }

    func testDeleteKindRetargetsClassificationRules() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        try repository.saveClassificationRule(
            ClassificationRuleRecord(source: .tag, value: "기도", targetKind: .prayer))
        // Run the first-refresh reconcile now so it cannot retarget the rule
        // on deleteKind's behalf.
        model.refresh()

        try model.deleteKind(.prayer, moveTo: .memo)

        XCTAssertEqual(try repository.classificationRules().map(\.targetKind), [.memo])
    }

    func testUnknownKindIdsShowInSidebarBeforeUnclassified() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let unknown = JournalKind(id: "custom-ZZZ")
        let entry = try repository.save(
            JournalEntryDraft(kind: unknown, body: "다른 기기에서 온 기록"), deviceID: "d", at: .now)

        model.refresh()

        XCTAssertEqual(model.unknownKinds, [unknown])
        let sidebar = model.sidebarKinds
        XCTAssertEqual(sidebar.last?.kind, .unclassified)
        XCTAssertEqual(sidebar.dropLast().last?.kind, unknown)
        XCTAssertEqual(sidebar.dropLast().last?.name, "이름 없는 유형")
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, unknown)

        // Selecting another kind filters the unknown entry out of `entries`;
        // its sidebar row must stay so the user can still reach it.
        model.selectKind(.diary)
        XCTAssertEqual(model.unknownKinds, [unknown])
        XCTAssertTrue(model.sidebarKinds.contains { $0.kind == unknown })
    }

    func testRenamingUnknownKindMakesItKnown() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let unknown = JournalKind(id: "custom-ZZZ")
        _ = try repository.save(
            JournalEntryDraft(kind: unknown, body: "다른 기기에서 온 기록"), deviceID: "d", at: .now)
        model.refresh()

        try model.updateKind(unknown, name: "설교노트", colorToken: .rose, iconToken: "star")

        XCTAssertEqual(model.unknownKinds, [])
        XCTAssertEqual(model.sidebarKinds.filter { $0.kind == unknown }.map(\.name), ["설교노트"])
    }

    func testDeleteKindReloadsTheOpenEditorOfAMovedEntry() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "열어 둔 기도"), deviceID: "d", at: .now)
        let untouched = try repository.save(
            JournalEntryDraft(kind: .diary, body: "일기"), deviceID: "d", at: .now)
        model.refresh()
        model.selectEntry(entry.id)
        XCTAssertNil(model.editorReloadRequest)

        try model.deleteKind(.prayer, moveTo: .memo)

        let request = try XCTUnwrap(model.editorReloadRequest)
        XCTAssertTrue(request.entryIDs.contains(entry.id))
        XCTAssertFalse(request.entryIDs.contains(untouched.id))
        XCTAssertEqual(model.selectedEntryID, entry.id)
        XCTAssertEqual(model.selectedEntry?.kind, .memo)
    }

    func testReconcileReloadsTheOpenEditorOfAMovedEntry() throws {
        let modelA = try makeModel()
        try modelA.deleteKind(.prayer, moveTo: .memo)
        let repository = InMemoryJournalRepository()
        let modelB = try makeModel(repository: repository)
        let entry = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "열어 둔 기도"), deviceID: "d", at: .now)
        modelB.refresh()
        modelB.selectEntry(entry.id)
        let before = modelB.editorReloadRequest

        modelB.adoptKindCatalog(modelA.kindCatalog)

        let request = try XCTUnwrap(modelB.editorReloadRequest)
        XCTAssertNotEqual(request, before)
        XCTAssertTrue(request.entryIDs.contains(entry.id))
        XCTAssertEqual(try repository.entry(id: entry.id)?.kind, .memo)
        // Callers (backup restore, scope migration) refresh afterwards.
        modelB.refresh()
        XCTAssertEqual(modelB.selectedEntry?.kind, .memo)
    }

    /// The editor's save refreshes, and a refresh can reconcile kinds. The
    /// reconcile's editor flush must not save the same editor again from
    /// inside its own save: a new entry has no ID yet at that point, so the
    /// nested save would create a second copy of it.
    func testReconcileInsideAnEditorSaveDoesNotSaveTheEditorAgain() throws {
        let defaults = makeDefaults()
        try makeModel(defaults: defaults).deleteKind(.prayer, moveTo: .memo)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(defaults: defaults, repository: repository)
        let draft = JournalEntryDraft(kind: .diary, body: "처음 쓰는 기록")
        // Stands in for an open editor whose entry is not saved yet: it
        // answers the flush by saving its draft, still without an ID.
        let observer = NotificationCenter.default.addObserver(
            forName: .saveJournalEntry, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { _ = model.saveAndReturnRecord(draft, closeEditor: false) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The model's first refresh, here inside the save, reconciles kinds.
        _ = model.saveAndReturnRecord(draft, closeEditor: false)

        let saved = try repository.list(kind: nil, includeDeleted: false, limit: 100)
        XCTAssertEqual(saved.filter { $0.body == "처음 쓰는 기록" }.count, 1)
    }

    func testDeleteKindMovesTheRestWhenOneEntryFailsToSave() throws {
        let base = InMemoryJournalRepository()
        let broken = try base.save(
            JournalEntryDraft(kind: .prayer, body: "저장되지 않는 기도"), deviceID: "d", at: .now)
        let fine = try base.save(
            JournalEntryDraft(kind: .prayer, body: "옮겨지는 기도"), deviceID: "d", at: .now)
        let model = try makeModel(
            repository: SaveRefusingRepository(base: base, refusedEntryIDs: [broken.id]))
        model.refresh()

        XCTAssertThrowsError(try model.deleteKind(.prayer, moveTo: .memo)) { error in
            XCTAssertNotNil(error as? KindMoveError)
            XCTAssertTrue(error.localizedDescription.contains("기록 1개"))
        }

        XCTAssertEqual(try base.entry(id: fine.id)?.kind, .memo)
        XCTAssertEqual(try base.entry(id: broken.id)?.kind, .prayer)
        let hits = try model.searchIndex.search(JournalSearchQuery(text: "옮겨지는", kind: .memo))
        XCTAssertEqual(hits.map(\.id), [fine.id])
        XCTAssertEqual(model.editorReloadRequest?.entryIDs, [fine.id])
        XCTAssertFalse(model.kindCatalog.activeKinds.contains { $0.kind == .prayer })
    }

    func testEditorForUnknownKindStartsWithEmptyName() {
        let unknown = KindCatalog.unknownDefinition(for: JournalKind(id: "custom-ZZZ"))
        XCTAssertEqual(KindDetailEditor.initialName(editing: unknown, isKnown: false), "")
        XCTAssertEqual(KindDetailEditor.initialName(editing: nil, isKnown: true), "")
        let memo = KindCatalog.defaultDefinition(for: .memo)
        XCTAssertEqual(KindDetailEditor.initialName(editing: memo, isKnown: true), memo.name)
    }

    func testRenamingUnknownKindStillRequiresAName() throws {
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let unknown = JournalKind(id: "custom-ZZZ")
        _ = try repository.save(
            JournalEntryDraft(kind: unknown, body: "다른 기기에서 온 기록"), deviceID: "d", at: .now)
        model.refresh()

        XCTAssertThrowsError(
            try model.updateKind(unknown, name: "  ", colorToken: .rose, iconToken: "star")
        ) { XCTAssertEqual($0 as? KindCatalogError, .emptyName) }
        XCTAssertEqual(model.unknownKinds, [unknown])
    }

    func testLockedAccessShowsPremiumNoticeInsteadOfEditor() throws {
        let model = try makeModel(featureAccess: LockedFeatureAccess())

        model.openKindManagement()

        XCTAssertTrue(model.isPresentingPremiumNotice)
        XCTAssertFalse(model.isPresentingKindManagement)
    }

    func testUnlockedAccessOpensKindManagement() throws {
        let model = try makeModel()

        model.openKindManagement()

        XCTAssertTrue(model.isPresentingKindManagement)
        XCTAssertFalse(model.isPresentingPremiumNotice)
    }

    func testBackupRoundTripRestoresKindCatalog() async throws {
        let modelA = try makeModel()
        let created = try modelA.createKind(name: "설교노트", colorToken: .teal, iconToken: "star")
        await modelA.prepareBackup()
        let data = try XCTUnwrap(modelA.backupDocument?.data)

        let modelB = try makeModel()
        await modelB.restoreBackup(data: data, mode: .merge)

        XCTAssertNil(modelB.lastRestoreFailureMessage)
        XCTAssertEqual(
            modelB.kindCatalog.creatableKinds.first { $0.kind == created }?.name, "설교노트")
    }

    func testAdoptKindCatalogMergesAndReconciles() throws {
        let modelA = try makeModel()
        let custom = try modelA.createKind(name: "설교노트", colorToken: .teal, iconToken: "star")
        try modelA.deleteKind(.prayer, moveTo: .memo)
        let repository = InMemoryJournalRepository()
        let modelB = try makeModel(repository: repository)
        let prayer = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "손으로 쓴 기도"), deviceID: "d", at: .now)
        modelB.refresh()
        modelB.selectKind(.prayer)

        modelB.adoptKindCatalog(modelA.kindCatalog)

        XCTAssertEqual(
            modelB.kindCatalog.creatableKinds.first { $0.kind == custom }?.name, "설교노트")
        XCTAssertFalse(modelB.kindCatalog.activeKinds.contains { $0.kind == .prayer })
        XCTAssertNil(modelB.selectedKind)
        XCTAssertEqual(try repository.entry(id: prayer.id)?.kind, .memo)
        let hits = try modelB.searchIndex.search(JournalSearchQuery(text: "손으로", kind: .memo))
        XCTAssertEqual(hits.map(\.id), [prayer.id])
    }

    func testFirstRefreshReconcilesEntriesOfDeletedKinds() throws {
        let defaults = makeDefaults()
        try makeModel(defaults: defaults).deleteKind(.prayer, moveTo: .memo)
        let repository = InMemoryJournalRepository()
        let late = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "늦게 온 기록"), deviceID: "other", at: .now)
        let model = try makeModel(defaults: defaults, repository: repository)

        model.refresh()

        XCTAssertEqual(try repository.entry(id: late.id)?.kind, .memo)

        // Later refreshes (kind or notebook selection) skip the full scan.
        let later = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "또 늦게 온 기록"), deviceID: "other", at: .now)
        model.refresh()
        XCTAssertEqual(try repository.entry(id: later.id)?.kind, .prayer)
    }

    func testCloudImportCompletionReconcilesEntriesOfDeletedKinds() throws {
        let defaults = makeDefaults()
        try makeModel(defaults: defaults).deleteKind(.prayer, moveTo: .memo)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(
            defaults: defaults,
            repository: repository,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal")
        )
        model.refresh()
        let imported = try repository.save(
            JournalEntryDraft(kind: .prayer, body: "동기화로 온 기록"), deviceID: "other", at: .now)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(operation: .importing, completedAt: .now, succeeded: true))

        XCTAssertEqual(try repository.entry(id: imported.id)?.kind, .memo)
    }
}
/// Forwards to an in-memory repository but refuses to save chosen entries.
@MainActor
private final class SaveRefusingRepository: JournalRepository {
    let base: InMemoryJournalRepository
    let refusedEntryIDs: Set<UUID>

    init(base: InMemoryJournalRepository, refusedEntryIDs: Set<UUID>) {
        self.base = base
        self.refusedEntryIDs = refusedEntryIDs
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
        if let id = draft.id, refusedEntryIDs.contains(id) {
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
