#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

@testable import JournalData

@MainActor
final class PrayerTemplateStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pilgrim-prayer-templates-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSaveWritesBothStoresAndReloads() throws {
        let cloud = FakeCloudStore()
        let store = PrayerTemplateStore(defaults: defaults, cloudStore: cloud)
        var catalog = PrayerTemplateCatalog()
        catalog.upsert(
            name: "가족 기도", categories: ["감사", "중보"],
            at: Date(timeIntervalSince1970: 100))
        store.save(catalog)

        XCTAssertNotNil(defaults.data(forKey: PrayerTemplateStore.key))
        XCTAssertNotNil(cloud.storage[PrayerTemplateStore.key])

        let reloaded = PrayerTemplateStore(defaults: defaults, cloudStore: cloud)
        XCTAssertEqual(reloaded.catalog.activeTemplates.map(\.name), ["가족 기도"])
    }

    func testMergeFromCloudCombinesTemplates() throws {
        let cloud = FakeCloudStore()
        var remote = PrayerTemplateCatalog()
        remote.upsert(
            name: "새벽", categories: ["말씀"], at: Date(timeIntervalSince1970: 50))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        cloud.storage[PrayerTemplateStore.key] = try encoder.encode(remote)

        let store = PrayerTemplateStore(defaults: defaults, cloudStore: cloud)
        var local = store.catalog
        local.upsert(
            name: "가족", categories: ["감사"], at: Date(timeIntervalSince1970: 100))
        store.save(local)

        XCTAssertTrue(store.mergeFromCloud() == false)
        XCTAssertEqual(store.catalog.activeTemplates.map(\.name), ["가족", "새벽"])
    }
}
#endif
