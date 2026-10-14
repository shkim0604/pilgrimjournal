#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

@MainActor
final class NewEntryDefaultsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-new-entry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() throws -> AppModel {
        let paths = JournalPaths(root: root)
        try paths.prepare()
        return try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(url: paths.search.appending(path: "index.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: UserDefaults(suiteName: "pilgrim-new-entry-\(UUID().uuidString)")!
        )
    }

    func testNewEntryDefaultsToDiaryWhenNoKindIsSelected() throws {
        let model = try makeModel()
        model.selectedKind = nil
        XCTAssertEqual(model.defaultKindForNewEntry, .diary)
    }

    func testNewEntryUsesTheSelectedKindWhenItCanBeCreatedManually() throws {
        let model = try makeModel()
        model.selectedKind = .prayer
        XCTAssertEqual(model.defaultKindForNewEntry, .prayer)
    }

    func testNewEntryFallsBackToDiaryWhileUnclassifiedIsSelected() throws {
        let model = try makeModel()
        model.selectedKind = .unclassified
        XCTAssertEqual(model.defaultKindForNewEntry, .diary)
    }
}
#endif
