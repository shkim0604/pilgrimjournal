#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class SharedEntryMergeTests: XCTestCase {
    private let entryID = UUID()
    private let earlier = SharedEditStamp(
        updatedAt: Date(timeIntervalSince1970: 100), deviceID: "device-a")
    private let later = SharedEditStamp(
        updatedAt: Date(timeIntervalSince1970: 200), deviceID: "device-b")

    private var base: JournalEntryDraft {
        JournalEntryDraft(
            id: entryID,
            kind: .prayer,
            title: "11월 기도제목",
            body: "1. 아빠 건강\n2. 동생 수능\n3. 수련회",
            occurredAt: Date(timeIntervalSince1970: 0),
            tags: ["가족", "기도"],
            details: EntryDetails(prayerStatus: .ongoing)
        )
    }

    func testDifferentFieldsAndLinesFromBothSidesAreKept() {
        var local = base
        local.body = "1. 아빠 건강 회복\n2. 동생 수능\n3. 수련회"
        local.tags = ["가족", "기도", "11월"]
        var remote = base
        remote.body = "1. 아빠 건강\n2. 동생 수능\n3. 수련회 준비팀"
        remote.details = EntryDetails(
            prayerStatus: .answered, answeredAt: Date(timeIntervalSince1970: 50))

        let result = SharedEntryMerge.merge(
            base: base, local: local, localStamp: earlier, remote: remote, remoteStamp: later)

        XCTAssertEqual(result.draft.body, "1. 아빠 건강 회복\n2. 동생 수능\n3. 수련회 준비팀")
        XCTAssertEqual(result.draft.tags, ["11월", "가족", "기도"])
        XCTAssertEqual(result.draft.details.prayerStatus, .answered)
        XCTAssertNil(result.overwritten)
    }

    func testTagRemovedOnOneSideStaysRemoved() {
        var local = base
        local.tags = ["가족"]
        var remote = base
        remote.tags = ["가족", "기도", "감사"]

        let result = SharedEntryMerge.merge(
            base: base, local: local, localStamp: earlier, remote: remote, remoteStamp: later)

        XCTAssertEqual(result.draft.tags, ["가족", "감사"])
    }

    func testSameLineConflictUsesLaterEditAndKeepsTheOtherAsOverwritten() {
        var local = base
        local.body = "1. 아빠 건강 회복\n2. 동생 수능\n3. 수련회"
        var remote = base
        remote.body = "1. 아빠 건강검진 결과\n2. 동생 수능\n3. 수련회"

        let result = SharedEntryMerge.merge(
            base: base, local: local, localStamp: later, remote: remote, remoteStamp: earlier)

        XCTAssertEqual(result.draft.body, local.body)
        XCTAssertEqual(result.overwritten, remote)
    }

    func testScalarChangedDifferentlyOnBothSidesUsesLaterEdit() {
        var local = base
        local.kind = .diary
        var remote = base
        remote.kind = .memo

        let result = SharedEntryMerge.merge(
            base: base, local: local, localStamp: earlier, remote: remote, remoteStamp: later)

        XCTAssertEqual(result.draft.kind, .memo)
        XCTAssertEqual(result.overwritten, local)
    }

    func testEqualTimestampsBreakTiesByDeviceID() {
        let stampA = SharedEditStamp(
            updatedAt: Date(timeIntervalSince1970: 100), deviceID: "device-a")
        let stampB = SharedEditStamp(
            updatedAt: Date(timeIntervalSince1970: 100), deviceID: "device-b")
        var local = base
        local.title = "로컬 제목"
        var remote = base
        remote.title = "원격 제목"

        let result = SharedEntryMerge.merge(
            base: base, local: local, localStamp: stampA, remote: remote, remoteStamp: stampB)

        XCTAssertEqual(result.draft.title, "원격 제목")
    }

    func testWithoutBaseTheLaterEditWinsWholeAndTheOtherIsKept() {
        var local = base
        local.body = "로컬 본문"
        var remote = base
        remote.body = "원격 본문"

        let result = SharedEntryMerge.merge(
            base: nil, local: local, localStamp: earlier, remote: remote, remoteStamp: later)

        XCTAssertEqual(result.draft, remote)
        XCTAssertEqual(result.overwritten, local)
    }

    func testWithoutBaseIdenticalDraftsAreNotOverwritten() {
        let result = SharedEntryMerge.merge(
            base: nil, local: base, localStamp: earlier, remote: base, remoteStamp: later)

        XCTAssertEqual(result.draft, base)
        XCTAssertNil(result.overwritten)
    }
}
#endif
