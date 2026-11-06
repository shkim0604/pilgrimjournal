#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class PrayerTemplateCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_700_100_000)
    private let t2 = Date(timeIntervalSince1970: 1_700_200_000)

    func testUpsertTrimsAndSanitizes() throws {
        var catalog = PrayerTemplateCatalog()
        let saved = try XCTUnwrap(
            catalog.upsert(name: "  가족 기도  ", categories: [" 감사 ", "", "감사", "중보"], at: t0))
        XCTAssertEqual(saved.name, "가족 기도")
        XCTAssertEqual(saved.categories, ["감사", "중보"])
        XCTAssertEqual(catalog.activeTemplates, [saved])
        XCTAssertNil(catalog.upsert(name: "   ", categories: ["감사"], at: t0))
    }

    func testUpsertWithSameNameUpdatesExistingTemplate() throws {
        var catalog = PrayerTemplateCatalog()
        let first = try XCTUnwrap(catalog.upsert(name: "가족", categories: ["감사"], at: t0))
        let second = try XCTUnwrap(
            catalog.upsert(name: " 가족 ", categories: ["감사", "중보"], at: t1))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(catalog.activeTemplates.count, 1)
        XCTAssertEqual(catalog.activeTemplates.first?.categories, ["감사", "중보"])
    }

    func testDeleteLeavesTombstoneAndHidesTemplate() throws {
        var catalog = PrayerTemplateCatalog()
        let template = try XCTUnwrap(catalog.upsert(name: "가족", categories: ["감사"], at: t0))
        catalog.delete(id: template.id, at: t1)
        XCTAssertTrue(catalog.activeTemplates.isEmpty)
        XCTAssertEqual(catalog.templates.count, 1)
    }

    func testActiveTemplatesSortByName() throws {
        var catalog = PrayerTemplateCatalog()
        _ = catalog.upsert(name: "새벽", categories: ["감사"], at: t0)
        _ = catalog.upsert(name: "가족", categories: ["중보"], at: t0)
        XCTAssertEqual(catalog.activeTemplates.map(\.name), ["가족", "새벽"])
    }

    func testMergeIsLastWriteWinsPerTemplateAndDeterministic() throws {
        var mine = PrayerTemplateCatalog()
        let shared = try XCTUnwrap(mine.upsert(name: "가족", categories: ["감사"], at: t0))
        var theirs = mine

        _ = mine.upsert(name: "가족", categories: ["감사", "성훈"], at: t1)
        theirs.delete(id: shared.id, at: t2)
        _ = theirs.upsert(name: "새벽", categories: ["말씀"], at: t0)

        let merged = mine.merged(with: theirs)
        XCTAssertEqual(merged, theirs.merged(with: mine))
        XCTAssertEqual(merged.activeTemplates.map(\.name), ["새벽"])

        var revived = merged
        _ = revived.upsert(
            name: "가족", categories: ["감사"],
            at: Date(
                timeIntervalSince1970: 1_700_300_000))
        XCTAssertEqual(revived.activeTemplates.map(\.name), ["가족", "새벽"])
    }

    func testCatalogRoundTripsThroughCodable() throws {
        var catalog = PrayerTemplateCatalog()
        _ = catalog.upsert(name: "가족", categories: ["감사", "중보"], at: t0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PrayerTemplateCatalog.self, from: encoder.encode(catalog))
        XCTAssertEqual(decoded, catalog)
    }
}
#endif
