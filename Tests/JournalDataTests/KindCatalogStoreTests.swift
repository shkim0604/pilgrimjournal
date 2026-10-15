#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

@testable import JournalData

final class FakeCloudStore: KindCatalogCloudStore {
    var storage: [String: Data] = [:]
    var synchronizeCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func set(_ data: Data?, forKey key: String) {
        storage[key] = data
    }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}

@MainActor
final class KindCatalogStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pilgrim-kinds-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func definition(name: String, at seconds: TimeInterval) -> KindDefinition {
        KindDefinition(
            kind: JournalKind(id: "memo"),
            name: name,
            colorToken: .stone,
            iconToken: "note.text",
            order: 4,
            state: .active,
            updatedAt: Date(timeIntervalSince1970: seconds),
            modifiedByDeviceID: "device-a"
        )
    }

    private func encode(_ catalog: KindCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    func testSaveWritesBothStoresAndReloads() {
        let cloud = FakeCloudStore()
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        let catalog = KindCatalog(definitions: [definition(name: "메모장", at: 100)])
        store.save(catalog)

        XCTAssertNotNil(defaults.data(forKey: KindCatalogStore.key))
        XCTAssertNotNil(cloud.storage[KindCatalogStore.key])
        XCTAssertGreaterThan(cloud.synchronizeCount, 0)

        let reloaded = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(reloaded.catalog, catalog)
    }

    func testMergeFromCloudAdoptsNewerRemoteEdit() throws {
        let cloud = FakeCloudStore()
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        store.save(KindCatalog(definitions: [definition(name: "메모", at: 100)]))

        let remote = KindCatalog(definitions: [definition(name: "아이디어", at: 200)])
        cloud.storage[KindCatalogStore.key] = try encode(remote)

        XCTAssertTrue(store.mergeFromCloud())
        XCTAssertEqual(store.catalog.definitions.first?.name, "아이디어")

        let localData = try XCTUnwrap(defaults.data(forKey: KindCatalogStore.key))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let local = try decoder.decode(KindCatalog.self, from: localData)
        XCTAssertEqual(local.definitions.first?.name, "아이디어")
    }

    func testMergeFromCloudReturnsFalseWhenUnchanged() {
        let cloud = FakeCloudStore()
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        store.save(KindCatalog(definitions: [definition(name: "메모", at: 100)]))
        XCTAssertFalse(store.mergeFromCloud())
    }

    func testCorruptStoredCatalogFallsBackWithoutOverwritingCloud() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: KindCatalogStore.key)
        let cloud = FakeCloudStore()
        cloud.storage[KindCatalogStore.key] = garbage

        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(store.catalog, KindCatalog())
        XCTAssertEqual(cloud.storage[KindCatalogStore.key], garbage)
    }

    func testWorksWithoutCloudStore() {
        let store = KindCatalogStore(defaults: defaults, cloudStore: nil)
        let catalog = KindCatalog(definitions: [definition(name: "메모장", at: 100)])
        store.save(catalog)
        XCTAssertEqual(KindCatalogStore(defaults: defaults, cloudStore: nil).catalog, catalog)
    }
}
#endif
