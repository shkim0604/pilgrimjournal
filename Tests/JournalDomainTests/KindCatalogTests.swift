#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class KindCatalogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func assertThrows(
        _ expected: KindCatalogError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as KindCatalogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    @discardableResult
    private func make(_ catalog: inout KindCatalog, _ name: String) throws -> KindDefinition {
        try catalog.create(
            name: name, colorToken: .teal, iconToken: "tag", deviceID: "A", at: t0)
    }

    func testEmptyCatalogMatchesCurrentKinds() {
        let catalog = KindCatalog()
        XCTAssertEqual(catalog.activeKinds.map(\.kind), JournalKind.builtIns)
        XCTAssertEqual(catalog.creatableKinds.count, 5)
        XCTAssertEqual(catalog.activeKinds.last?.kind, .unclassified)
        XCTAssertFalse(catalog.hasDeletedKinds)
    }

    func testCreateValidatesName() throws {
        var catalog = KindCatalog()
        assertThrows(.emptyName) { _ = try make(&catalog, "  ") }
        assertThrows(.nameTooLong) { _ = try make(&catalog, String(repeating: "가", count: 21)) }
        _ = try make(&catalog, String(repeating: "가", count: 20))
        assertThrows(.duplicateName("메모")) { _ = try make(&catalog, "메모") }
        _ = try make(&catalog, "Work")
        assertThrows(.duplicateName("WORK")) { _ = try make(&catalog, "WORK") }
    }

    func testCreateAppendsBeforeUnclassified() throws {
        var catalog = KindCatalog()
        let created = try make(&catalog, "설교노트")
        let kinds = catalog.activeKinds.map(\.kind)
        XCTAssertEqual(kinds[kinds.count - 2], created.kind)
        XCTAssertEqual(kinds.last, .unclassified)
    }

    func testUnclassifiedIsLocked() {
        var catalog = KindCatalog()
        assertThrows(.systemKindLocked) {
            try catalog.update(
                .unclassified, name: "x", colorToken: .rose, iconToken: "tag",
                deviceID: "A", at: t0)
        }
        assertThrows(.systemKindLocked) {
            try catalog.delete(.unclassified, moveTarget: .memo, deviceID: "A", at: t0)
        }
        assertThrows(.systemKindLocked) {
            try catalog.reorder([.unclassified, .memo], deviceID: "A", at: t0)
        }
    }

    func testOnlyMemoAndCustomKindsCanBeDeletedFromTheApp() {
        XCTAssertEqual(
            JournalKind.builtIns.filter(\.canBeDeleted), [.memo])
        XCTAssertTrue(JournalKind.custom().canBeDeleted)
    }

    func testDeleteRequiresActiveOtherTarget() throws {
        var catalog = KindCatalog()
        assertThrows(.invalidMoveTarget) {
            try catalog.delete(.prayer, moveTarget: .prayer, deviceID: "A", at: t0)
        }
        try catalog.delete(.diary, moveTarget: .memo, deviceID: "A", at: t0)
        assertThrows(.invalidMoveTarget) {
            try catalog.delete(.prayer, moveTarget: .diary, deviceID: "A", at: t0)
        }
    }

    func testCannotDeleteLastCreatableKind() throws {
        var catalog = KindCatalog()
        try catalog.delete(.prayer, moveTarget: .memo, deviceID: "A", at: t0)
        try catalog.delete(.bibleStudy, moveTarget: .memo, deviceID: "A", at: t0)
        try catalog.delete(.reading, moveTarget: .memo, deviceID: "A", at: t0)
        try catalog.delete(.diary, moveTarget: .memo, deviceID: "A", at: t0)
        assertThrows(.lastCreatableKind) {
            try catalog.delete(.memo, moveTarget: .unclassified, deviceID: "A", at: t0)
        }
        XCTAssertEqual(catalog.creatableKinds.map(\.kind), [.memo])
    }

    func testRestoreBuiltInAndRejectCustom() throws {
        var catalog = KindCatalog()
        try catalog.delete(.prayer, moveTarget: .memo, deviceID: "A", at: t0)
        XCTAssertEqual(catalog.deletedBuiltIns.map(\.kind), [.prayer])
        XCTAssertTrue(catalog.hasDeletedKinds)
        try catalog.restore(.prayer, deviceID: "A", at: t1)
        let prayer = catalog.definition(for: .prayer)
        XCTAssertTrue(prayer.isActive)
        let maxOrder = catalog.creatableKinds.map(\.order).max()
        XCTAssertEqual(prayer.order, maxOrder)
        XCTAssertEqual(catalog.creatableKinds.last?.kind, .prayer)

        let custom = try make(&catalog, "설교노트")
        try catalog.delete(custom.kind, moveTarget: .memo, deviceID: "A", at: t1)
        assertThrows(.customKindCannotBeRestored) {
            try catalog.restore(custom.kind, deviceID: "A", at: t1)
        }
        assertThrows(.notDeleted) { try catalog.restore(.memo, deviceID: "A", at: t1) }
    }

    func testRestoreRejectsNameTakenByAnotherActiveKind() throws {
        var catalog = KindCatalog()
        try catalog.delete(.prayer, moveTarget: .memo, deviceID: "A", at: t0)
        _ = try make(&catalog, "기도노트")
        assertThrows(.duplicateName("기도노트")) {
            try catalog.restore(.prayer, deviceID: "A", at: t1)
        }
    }

    func testMergePicksNewerThenDeviceID() throws {
        var older = KindCatalog()
        try older.update(
            .memo, name: "A안", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t0)
        var newer = KindCatalog()
        try newer.update(
            .memo, name: "B안", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t1)
        XCTAssertEqual(older.merged(with: newer).definition(for: .memo).name, "B안")
        XCTAssertEqual(newer.merged(with: older).definition(for: .memo).name, "B안")

        var deviceA = KindCatalog()
        try deviceA.update(
            .memo, name: "from A", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t1)
        var deviceB = KindCatalog()
        try deviceB.update(
            .memo, name: "from B", colorToken: .rose, iconToken: "tag", deviceID: "B", at: t1)
        XCTAssertEqual(deviceA.merged(with: deviceB).definition(for: .memo).name, "from B")
        XCTAssertEqual(deviceB.merged(with: deviceA).definition(for: .memo).name, "from B")
    }

    func testMergeKeepsConcurrentKindsWithSameName() throws {
        var first = KindCatalog()
        var second = KindCatalog()
        try make(&first, "설교노트")
        try make(&second, "설교노트")
        let merged = first.merged(with: second)
        let customs = merged.activeKinds.filter { $0.kind.builtIn == nil }
        XCTAssertEqual(customs.count, 2)
    }

    func testResolvedTargetFollowsChainAndBreaksCycles() {
        let x = JournalKind(id: "custom-X")
        let y = JournalKind(id: "custom-Y")
        let z = JournalKind(id: "custom-Z")
        let a = JournalKind(id: "custom-A")
        let b = JournalKind(id: "custom-B")
        func def(_ kind: JournalKind, _ state: KindState) -> KindDefinition {
            var d = KindCatalog.unknownDefinition(for: kind)
            d.state = state
            return d
        }
        let catalog = KindCatalog(definitions: [
            def(x, .deleted(moveTarget: y)),
            def(y, .deleted(moveTarget: z)),
            def(z, .active),
            def(a, .deleted(moveTarget: b)),
            def(b, .deleted(moveTarget: a)),
        ])
        XCTAssertEqual(catalog.resolvedTarget(for: x), z)
        XCTAssertEqual(catalog.resolvedTarget(for: a), .unclassified)
        XCTAssertEqual(catalog.resolvedTarget(for: b), .unclassified)
        XCTAssertNil(catalog.resolvedTarget(for: z))
        XCTAssertNil(catalog.resolvedTarget(for: JournalKind(id: "custom-nobody")))
        XCTAssertNil(catalog.resolvedTarget(for: .memo))
    }

    func testResolvedTargetFallsBackWhenChainReachesUnknownID() {
        var d = KindCatalog.unknownDefinition(for: JournalKind(id: "custom-X"))
        d.state = .deleted(moveTarget: JournalKind(id: "custom-ghost"))
        let catalog = KindCatalog(definitions: [d])
        XCTAssertEqual(catalog.resolvedTarget(for: d.kind), .unclassified)
    }

    func testUnknownKindIsRenamable() throws {
        var catalog = KindCatalog()
        let q = JournalKind(id: "custom-Q")
        XCTAssertFalse(catalog.isKnown(q))
        XCTAssertEqual(catalog.definition(for: q).name, "이름 없는 유형")
        try catalog.update(
            q, name: "설교", colorToken: .rose, iconToken: "heart", deviceID: "A", at: t0)
        XCTAssertTrue(catalog.isKnown(q))
        XCTAssertEqual(catalog.definition(for: q).name, "설교")
    }

    func testReorderMaterialisesUnknownKind() throws {
        var catalog = KindCatalog()
        let q = JournalKind(id: "custom-Q")
        try catalog.reorder([q, .memo], deviceID: "A", at: t1)
        XCTAssertTrue(catalog.isKnown(q))
        let def = catalog.definition(for: q)
        XCTAssertTrue(def.isActive)
        XCTAssertEqual(def.order, 0)
        XCTAssertEqual(catalog.definition(for: .memo).order, 1)
    }

    func testDeleteUnknownKindLeavesTombstone() throws {
        var catalog = KindCatalog()
        let q = JournalKind(id: "custom-Q")
        try catalog.delete(q, moveTarget: .memo, deviceID: "A", at: t1)
        XCTAssertTrue(catalog.isKnown(q))
        XCTAssertEqual(catalog.definition(for: q).state, .deleted(moveTarget: .memo))
        XCTAssertEqual(catalog.resolvedTarget(for: q), .memo)
    }

    func testReorderOnlyTouchesChangedDefinitions() throws {
        var catalog = KindCatalog()
        try catalog.reorder(
            [.prayer, .bibleStudy, .reading, .memo, .diary], deviceID: "A", at: t1)
        XCTAssertEqual(catalog.definition(for: .memo).order, 3)
        XCTAssertEqual(catalog.definition(for: .memo).updatedAt, t1)
        XCTAssertEqual(catalog.definition(for: .prayer).updatedAt, .distantPast)
    }

    func testCatalogJSONRoundTrip() throws {
        var catalog = KindCatalog()
        let custom = try make(&catalog, "설교노트")
        try catalog.delete(.prayer, moveTarget: custom.kind, deviceID: "A", at: t1)
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(KindCatalog.self, from: data)
        XCTAssertEqual(decoded, catalog)
    }

    func testIconFallback() {
        XCTAssertEqual(KindIconCatalog.displaySymbol(for: "nope"), "tag")
        XCTAssertEqual(KindIconCatalog.displaySymbol(for: "heart"), "heart")
        XCTAssertEqual(KindIconCatalog.symbols.count, 20)
    }

    func testErrorDescriptions() {
        XCTAssertEqual(KindCatalogError.duplicateName("메모").errorDescription, "‘메모’ 유형이 이미 있습니다.")
        XCTAssertEqual(KindCatalogError.emptyName.errorDescription, "유형 이름을 입력해 주세요.")
    }

    /// 미분류 can never be deleted through the API; a catalog that says so
    /// anyway (crafted or corrupt) must not send its entries anywhere.
    func testResolvedTargetIgnoresUnclassifiedMarkedDeleted() {
        var unclassified = KindCatalog.defaultDefinition(for: .unclassified)
        unclassified.state = .deleted(moveTarget: .memo)
        var memo = KindCatalog.defaultDefinition(for: .memo)
        memo.state = .deleted(moveTarget: .unclassified)
        let catalog = KindCatalog(definitions: [unclassified, memo])
        XCTAssertNil(catalog.resolvedTarget(for: .unclassified))
        XCTAssertEqual(catalog.resolvedTarget(for: .memo), .unclassified)
    }

    /// Two quick edits on one device must stay ordered once timestamps are
    /// cut to whole seconds, or the byte tie-break could revert the second.
    func testSameInstantEditsGetStrictlyIncreasingStamps() throws {
        var catalog = KindCatalog()
        try catalog.reorder([.memo, .prayer, .bibleStudy, .reading, .diary], deviceID: "A", at: t1)
        let firstReorder = catalog.definition(for: .memo).updatedAt
        try catalog.reorder([.prayer, .memo, .bibleStudy, .reading, .diary], deviceID: "A", at: t1)
        XCTAssertGreaterThan(catalog.definition(for: .memo).updatedAt, firstReorder)

        try catalog.update(
            .diary, name: "하루", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t1)
        let intermediate = catalog
        try catalog.update(
            .diary, name: "하루 일기", colorToken: .amber, iconToken: "tag", deviceID: "A", at: t1)
        let final = catalog
        XCTAssertGreaterThan(
            final.definition(for: .diary).updatedAt,
            intermediate.definition(for: .diary).updatedAt)

        // Whole-second normalisation, as the catalog store applies it.
        func roundTripped(_ catalog: KindCatalog) throws -> KindCatalog {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(KindCatalog.self, from: encoder.encode(catalog))
        }
        let fractional = Date(timeIntervalSince1970: 3_000.4)
        var quick = KindCatalog()
        try quick.update(
            .diary, name: "나", colorToken: .rose, iconToken: "tag", deviceID: "A", at: fractional)
        let quickIntermediate = try roundTripped(quick)
        try quick.update(
            .diary, name: "가", colorToken: .rose, iconToken: "tag", deviceID: "A",
            at: fractional.addingTimeInterval(0.3))
        let quickFinal = try roundTripped(quick)
        for merged in [
            quickIntermediate.merged(with: quickFinal), quickFinal.merged(with: quickIntermediate),
        ] {
            XCTAssertEqual(merged.definition(for: .diary).name, "가")
        }
        XCTAssertEqual(intermediate.merged(with: final).definition(for: .diary).name, "하루 일기")
        XCTAssertEqual(final.merged(with: intermediate).definition(for: .diary).name, "하루 일기")
    }

    func testMutationStampNeverGoesBackwards() throws {
        var catalog = KindCatalog()
        try catalog.update(
            .diary, name: "하루", colorToken: .rose, iconToken: "tag", deviceID: "A", at: t1)
        // A clock that moved backwards still yields a later stamp.
        try catalog.delete(.diary, moveTarget: .memo, deviceID: "A", at: t0)
        XCTAssertEqual(
            catalog.definition(for: .diary).updatedAt, t1.addingTimeInterval(1))
        try catalog.restore(.diary, deviceID: "A", at: t0)
        XCTAssertEqual(
            catalog.definition(for: .diary).updatedAt, t1.addingTimeInterval(2))
    }

    func testMergeIsCommutativeAndIdempotent() {
        func def(_ id: String, _ name: String, at seconds: TimeInterval) -> KindDefinition {
            KindDefinition(
                kind: JournalKind(id: id), name: name, colorToken: .stone, iconToken: "tag",
                order: 1, state: .active, updatedAt: Date(timeIntervalSince1970: seconds),
                modifiedByDeviceID: "dev")
        }
        let a = KindCatalog(definitions: [
            def("z", "Z", at: 10), def("m", "tie-one", at: 5), def("a", "A-old", at: 1),
        ])
        let b = KindCatalog(definitions: [
            def("a", "A-new", at: 2), def("m", "tie-two", at: 5), def("q", "Q", at: 3),
        ])
        XCTAssertEqual(a.merged(with: b), b.merged(with: a))
        XCTAssertEqual(a.merged(with: b).merged(with: b), a.merged(with: b))
        XCTAssertEqual(a.merged(with: b).definitions.map(\.id), ["a", "m", "q", "z"])
    }
}
#endif
