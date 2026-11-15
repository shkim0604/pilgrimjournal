#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

/// The scrap kind (design.md 15절 "유형"): a built-in added at the end, hidden until the first
/// scrap stores it, so nothing changes for users who never scrap.
final class ScrapKindCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    /// The JSON an existing user's device stores today (sorted keys, ISO 8601 dates): memo
    /// renamed and moved first, diary deleted into memo, one custom kind.
    private let existingCatalogJSON =
        #"{"definitions":[{"colorToken":"rose","iconToken":"heart","kind":"custom-6B1C1E39-5A0A-4F62-9C67-1E1A2C3D4E5F","modifiedByDeviceID":"A","name":"설교노트","order":5,"state":{"active":{}},"updatedAt":"2026-01-02T03:04:05Z"},{"colorToken":"clay","iconToken":"pencil.and.scribble","kind":"diary","modifiedByDeviceID":"A","name":"일기","order":3,"state":{"deleted":{"moveTarget":"memo"}},"updatedAt":"2026-01-02T03:04:06Z"},{"colorToken":"iris","iconToken":"note.text","kind":"memo","modifiedByDeviceID":"B","name":"메모장","order":0,"state":{"active":{}},"updatedAt":"2026-01-02T03:04:07Z"}]}"#

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: Built-ins stay as they were

    func testBuiltInRawValuesColoursIconsAndOrderAreUnchanged() {
        let expected: [(BuiltInKind, String, String, KindColorToken, String)] = [
            (.prayer, "prayer", "기도노트", .amber, "hands.sparkles"),
            (.bibleStudy, "bibleStudy", "성경공부", .sage, "book.closed"),
            (.reading, "reading", "독서노트", .slate, "books.vertical"),
            (.diary, "diary", "일기", .clay, "pencil.and.scribble"),
            (.memo, "memo", "메모", .iris, "note.text"),
            (.unclassified, "unclassified", "미분류", .stone, "tray"),
            (.scrap, "scrap", "스크랩", .teal, "bookmark"),
        ]
        XCTAssertEqual(BuiltInKind.allCases, expected.map(\.0))
        for (index, (kind, raw, name, color, icon)) in expected.enumerated() {
            let definition = KindCatalog.defaultDefinition(for: kind)
            XCTAssertEqual(kind.rawValue, raw)
            XCTAssertEqual(definition.name, name)
            XCTAssertEqual(definition.colorToken, color, "\(kind)")
            XCTAssertEqual(definition.iconToken, icon, "\(kind)")
            XCTAssertEqual(definition.order, index, "\(kind)")
            XCTAssertEqual(definition.state, .active)
        }
        XCTAssertEqual(Array(KindIconCatalog.symbols.prefix(7)), expected.map(\.4))
    }

    func testScrapCannotBeCreatedByHandButCanBeDeleted() {
        XCTAssertFalse(BuiltInKind.scrap.canCreateManually)
        XCTAssertTrue(BuiltInKind.scrap.canBeDeleted)
        XCTAssertTrue(BuiltInKind.scrap.appearsOnFirstUse)
        XCTAssertEqual(
            BuiltInKind.allCases.filter(\.appearsOnFirstUse), [.scrap],
            "every other built-in is listed from the start")
        XCTAssertEqual(
            BuiltInKind.allCases.filter { !$0.canCreateManually }, [.unclassified, .scrap])
    }

    func testScrapDetailsAreDroppedLikeMemo() throws {
        let details = EntryDetails(
            prayerStatus: .ongoing, scriptureReference: "요 3:16", bookTitle: "책", mood: "기쁨")
        XCTAssertEqual(try details.validated(for: .scrap), EntryDetails())
        XCTAssertNil(details.carryOverLines(from: .scrap, timeZoneIdentifier: nil))
    }

    // MARK: Hidden until the first scrap

    func testScrapIsHiddenUntilStored() {
        let catalog = KindCatalog()
        XCTAssertFalse(catalog.allDefinitions.contains { $0.kind == .scrap })
        XCTAssertFalse(catalog.activeKinds.contains { $0.kind == .scrap })
        XCTAssertFalse(catalog.manageableKinds.contains { $0.kind == .scrap })
        XCTAssertFalse(catalog.creatableKinds.contains { $0.kind == .scrap })
        XCTAssertTrue(catalog.deletedBuiltIns.isEmpty)
        XCTAssertFalse(catalog.hasDeletedKinds)
        // An entry of the kind still has its look before the definition arrives.
        let fallback = catalog.definition(for: .scrap)
        XCTAssertEqual(fallback.name, "스크랩")
        XCTAssertEqual(fallback.colorToken, .teal)
        XCTAssertEqual(fallback.iconToken, "bookmark")
        XCTAssertNil(catalog.resolvedTarget(for: .scrap))
    }

    func testMaterializeListsScrapLastBeforeUnclassified() throws {
        var catalog = KindCatalog()
        let custom = try catalog.create(
            name: "설교노트", colorToken: .rose, iconToken: "heart", deviceID: "A", at: t0)

        let scrap = catalog.materialize(.scrap, deviceID: "B", at: t1)

        XCTAssertEqual(scrap.kind, .scrap)
        XCTAssertEqual(scrap.name, "스크랩")
        XCTAssertEqual(scrap.colorToken, .teal)
        XCTAssertEqual(scrap.iconToken, "bookmark")
        XCTAssertEqual(scrap.updatedAt, t1)
        XCTAssertEqual(scrap.modifiedByDeviceID, "B")
        XCTAssertEqual(scrap.order, custom.order + 1)
        XCTAssertEqual(catalog.definition(for: .scrap), scrap)
        XCTAssertEqual(
            catalog.activeKinds.map(\.kind),
            [.prayer, .bibleStudy, .reading, .diary, .memo, custom.kind, .scrap, .unclassified])
        XCTAssertEqual(catalog.manageableKinds.last?.kind, .scrap)
        XCTAssertFalse(catalog.creatableKinds.contains { $0.kind == .scrap })
        XCTAssertEqual(catalog.creatableKinds.count, 6)

        // A later kind still goes after scrap.
        let later = try catalog.create(
            name: "감사", colorToken: .sage, iconToken: "star", deviceID: "A", at: t1)
        XCTAssertEqual(later.order, scrap.order + 1)
    }

    func testMaterializeAgainChangesNothing() {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: t0)
        let once = catalog
        let again = catalog.materialize(.scrap, deviceID: "B", at: t1)
        XCTAssertEqual(catalog, once)
        XCTAssertEqual(again.updatedAt, t0)
    }

    func testMaterializeRenamesWhenScrapIsTaken() throws {
        var catalog = KindCatalog()
        try catalog.create(
            name: "스크랩", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t0)
        XCTAssertEqual(catalog.materialize(.scrap, deviceID: "A", at: t1).name, "그룹 스크랩")

        var crowded = KindCatalog()
        for name in ["스크랩", "그룹 스크랩"] {
            try crowded.create(
                name: name, colorToken: .rose, iconToken: "tag", deviceID: "A", at: t0)
        }
        XCTAssertEqual(crowded.materialize(.scrap, deviceID: "A", at: t1).name, "그룹 스크랩 2")
    }

    func testDeletedScrapComesBackOnTheNextScrap() throws {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: t0)
        try catalog.update(
            .scrap, name: "모임 글", colorToken: .teal, iconToken: "bookmark", deviceID: "A",
            at: t0)
        try catalog.delete(.scrap, moveTarget: .memo, deviceID: "A", at: t0)
        XCTAssertEqual(catalog.deletedBuiltIns.map(\.kind), [.scrap])
        XCTAssertEqual(catalog.resolvedTarget(for: .scrap), .memo)
        XCTAssertFalse(catalog.activeKinds.contains { $0.kind == .scrap })

        let restored = catalog.materialize(.scrap, deviceID: "A", at: t1)

        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(restored.name, "모임 글", "the user's own name survives")
        XCTAssertGreaterThan(restored.updatedAt, t0)
        XCTAssertTrue(catalog.deletedBuiltIns.isEmpty)
        XCTAssertNil(catalog.resolvedTarget(for: .scrap))
        XCTAssertEqual(catalog.manageableKinds.last?.kind, .scrap)
    }

    func testDeletedScrapCanAlsoBeRestoredByHand() throws {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: t0)
        try catalog.delete(.scrap, moveTarget: .memo, deviceID: "A", at: t0)
        try catalog.restore(.scrap, deviceID: "A", at: t1)
        XCTAssertTrue(catalog.definition(for: .scrap).isActive)
    }

    func testRestoringScrapAfterItsNameWasTakenFallsBack() throws {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: t0)
        try catalog.delete(.scrap, moveTarget: .memo, deviceID: "A", at: t0)
        try catalog.create(
            name: "스크랩", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t0)
        XCTAssertEqual(catalog.materialize(.scrap, deviceID: "A", at: t1).name, "그룹 스크랩")
    }

    func testScrapDoesNotCountAsTheLastCreatableKind() throws {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: t0)
        for kind in [JournalKind.prayer, .bibleStudy, .reading, .diary] {
            try catalog.delete(kind, moveTarget: .memo, deviceID: "A", at: t0)
        }
        XCTAssertThrowsError(
            try catalog.delete(.memo, moveTarget: .scrap, deviceID: "A", at: t0)
        ) { XCTAssertEqual($0 as? KindCatalogError, .lastCreatableKind) }
        // Scrap itself can still go: memo stays.
        try catalog.delete(.scrap, moveTarget: .memo, deviceID: "A", at: t0)
        XCTAssertEqual(catalog.creatableKinds.map(\.kind), [.memo])
    }

    func testScrapFromAnotherDeviceAppearsOnMerge() {
        var other = KindCatalog()
        other.materialize(.scrap, deviceID: "B", at: t1)
        let merged = KindCatalog().merged(with: other)
        XCTAssertTrue(merged.activeKinds.contains { $0.kind == .scrap })
    }

    // MARK: Existing users

    func testExistingCatalogJSONDecodesAndStaysTheSame() throws {
        let data = Data(existingCatalogJSON.utf8)
        let catalog = try decoder().decode(KindCatalog.self, from: data)
        let custom = JournalKind(id: "custom-6B1C1E39-5A0A-4F62-9C67-1E1A2C3D4E5F")

        XCTAssertEqual(
            catalog.activeKinds.map(\.kind),
            [.memo, .prayer, .bibleStudy, .reading, custom, .unclassified])
        XCTAssertEqual(catalog.creatableKinds.map(\.kind), catalog.manageableKinds.map(\.kind))
        XCTAssertEqual(catalog.deletedBuiltIns.map(\.kind), [.diary])
        XCTAssertEqual(catalog.definition(for: .memo).name, "메모장")
        XCTAssertFalse(catalog.isKnown(JournalKind(id: "custom-other")))
        XCTAssertTrue(catalog.isKnown(.scrap), "a built-in, even before it is stored")

        // Nothing is added or rewritten: the stored bytes come back unchanged.
        XCTAssertEqual(
            String(decoding: try encoder().encode(catalog), as: UTF8.self), existingCatalogJSON)
        // A kind created now gets the order it always would have.
        var edited = catalog
        let created = try edited.create(
            name: "감사", colorToken: .sage, iconToken: "star", deviceID: "A", at: t1)
        XCTAssertEqual(created.order, 6)
    }

    func testCatalogWithScrapRoundTrips() throws {
        var catalog = KindCatalog()
        catalog.materialize(.scrap, deviceID: "A", at: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try encoder().encode(catalog)
        XCTAssertEqual(try decoder().decode(KindCatalog.self, from: data), catalog)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""kind":"scrap""#))
    }
}
#endif
