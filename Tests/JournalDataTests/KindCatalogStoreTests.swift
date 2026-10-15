#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

@testable import JournalData

final class FakeCloudStore: KindCatalogCloudStore {
    var storage: [String: Data] = [:]
    var synchronizeCount = 0
    var setCount = 0

    func data(forKey key: String) -> Data? { storage[key] }

    func set(_ data: Data?, forKey key: String) {
        setCount += 1
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

    func testCorruptStoredCatalogFallsBackWithoutOverwritingCloud() throws {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: KindCatalogStore.key)
        let cloud = FakeCloudStore()
        cloud.storage[KindCatalogStore.key] = garbage

        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(store.catalog, KindCatalog())
        XCTAssertEqual(cloud.storage[KindCatalogStore.key], garbage)
        XCTAssertEqual(defaults.data(forKey: KindCatalogStore.key), garbage)

        // Corrupt cloud next to a valid local catalog.
        let valid = KindCatalog(definitions: [definition(name: "메모", at: 100)])
        defaults.set(try encode(valid), forKey: KindCatalogStore.key)
        let store2 = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(store2.catalog, valid)
        XCTAssertFalse(store2.mergeFromCloud())
        XCTAssertEqual(cloud.storage[KindCatalogStore.key], garbage)
    }

    func testMissingCloudReceivesLocalCatalog() throws {
        let local = KindCatalog(definitions: [definition(name: "메모", at: 100)])
        defaults.set(try encode(local), forKey: KindCatalogStore.key)
        let cloud = FakeCloudStore()
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(store.catalog, local)
        XCTAssertEqual(cloud.storage[KindCatalogStore.key], try encode(local))
        XCTAssertFalse(store.mergeFromCloud())
    }

    func testStaleCloudIsRepairedWithMerge() throws {
        var other = definition(name: "독서", at: 50)
        other.kind = JournalKind(id: "reading")
        let stale = KindCatalog(definitions: [other])
        let local = KindCatalog(definitions: [other, definition(name: "메모", at: 100)])
        defaults.set(try encode(local), forKey: KindCatalogStore.key)
        let cloud = FakeCloudStore()
        cloud.storage[KindCatalogStore.key] = try encode(stale)
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = try decoder.decode(
            KindCatalog.self, from: try XCTUnwrap(cloud.storage[KindCatalogStore.key]))
        XCTAssertEqual(stored, store.catalog)
        XCTAssertEqual(store.catalog.definitions.count, 2)
    }

    func testInitAdoptsCloudWhenLocalEmpty() throws {
        let remote = KindCatalog(definitions: [definition(name: "아이디어", at: 200)])
        let cloud = FakeCloudStore()
        cloud.storage[KindCatalogStore.key] = try encode(remote)
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(store.catalog, remote)
        XCTAssertEqual(defaults.data(forKey: KindCatalogStore.key), try encode(remote))
    }

    func testTwoDevicesConvergeWithoutFurtherWrites() throws {
        let cloud = FakeCloudStore()
        let nameB = "pilgrim-kinds-\(UUID().uuidString)"
        let defaultsB = UserDefaults(suiteName: nameB)!
        defer { defaultsB.removePersistentDomain(forName: nameB) }
        var other = definition(name: "독서", at: 150)
        other.kind = JournalKind(id: "reading")
        defaults.set(
            try encode(KindCatalog(definitions: [definition(name: "메모A", at: 100)])),
            forKey: KindCatalogStore.key)
        defaultsB.set(
            try encode(KindCatalog(definitions: [other, definition(name: "메모B", at: 200)])),
            forKey: KindCatalogStore.key)
        let a = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        let b = KindCatalogStore(defaults: defaultsB, cloudStore: cloud)
        a.mergeFromCloud()
        b.mergeFromCloud()
        let writes = cloud.setCount
        a.mergeFromCloud()
        b.mergeFromCloud()
        XCTAssertEqual(cloud.setCount, writes)
        XCTAssertEqual(a.catalog, b.catalog)
        XCTAssertEqual(a.catalog.definitions.count, 2)
    }

    func testSaveThenMergeDoesNotRewriteCloud() {
        let cloud = FakeCloudStore()
        let store = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        store.save(KindCatalog(definitions: [definition(name: "메모", at: 1_000.7)]))
        cloud.setCount = 0
        XCTAssertFalse(store.mergeFromCloud())
        XCTAssertEqual(cloud.setCount, 0)
    }

    func testSameSecondEditsConverge() {
        let cloud = FakeCloudStore()
        let nameB = "pilgrim-kinds-\(UUID().uuidString)"
        let defaultsB = UserDefaults(suiteName: nameB)!
        defer { defaultsB.removePersistentDomain(forName: nameB) }
        let a = KindCatalogStore(defaults: defaults, cloudStore: cloud)
        let b = KindCatalogStore(defaults: defaultsB, cloudStore: cloud)
        var defA = definition(name: "메모A", at: 1_000.7)
        defA.modifiedByDeviceID = "device-a"
        var defB = definition(name: "메모B", at: 1_000.3)
        defB.modifiedByDeviceID = "device-b"
        a.save(KindCatalog(definitions: [defA]))
        b.save(KindCatalog(definitions: [defB]))
        a.mergeFromCloud()
        b.mergeFromCloud()
        a.mergeFromCloud()
        let writes = cloud.setCount
        b.mergeFromCloud()
        a.mergeFromCloud()
        b.mergeFromCloud()
        XCTAssertEqual(cloud.setCount, writes)
        XCTAssertEqual(a.catalog, b.catalog)
    }

    func testStoredCatalogMatchesDecodedForm() {
        let store = KindCatalogStore(defaults: defaults, cloudStore: nil)
        store.save(KindCatalog(definitions: [definition(name: "메모", at: 1_000.7)]))
        let fresh = KindCatalogStore(defaults: defaults, cloudStore: nil)
        XCTAssertEqual(store.catalog, fresh.catalog)
    }

    func testWorksWithoutCloudStore() {
        let store = KindCatalogStore(defaults: defaults, cloudStore: nil)
        let catalog = KindCatalog(definitions: [definition(name: "메모장", at: 100)])
        store.save(catalog)
        XCTAssertEqual(KindCatalogStore(defaults: defaults, cloudStore: nil).catalog, catalog)
    }
}
#endif
