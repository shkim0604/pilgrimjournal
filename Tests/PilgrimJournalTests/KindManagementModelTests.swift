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
        repository: InMemoryJournalRepository = InMemoryJournalRepository(),
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
#endif
