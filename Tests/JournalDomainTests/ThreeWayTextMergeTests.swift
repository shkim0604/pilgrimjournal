#if canImport(XCTest)
import JournalDomain
import XCTest

final class ThreeWayTextMergeTests: XCTestCase {
    private let base = """
        1. 아빠 건강검진
        2. 동생 수능
        3. 수련회 준비
        """

    func testUnchangedSidesReturnBase() {
        let result = ThreeWayTextMerge.merge(base: base, local: base, remote: base, winner: .local)
        XCTAssertEqual(result, .init(text: base, hasConflicts: false))
    }

    func testOnlyLocalChangeIsKept() {
        let local = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 컨디션")
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: base, winner: .remote)
        XCTAssertEqual(result, .init(text: local, hasConflicts: false))
    }

    func testOnlyRemoteChangeIsKept() {
        let remote = base.replacingOccurrences(of: "수련회 준비", with: "수련회 준비팀")
        let result = ThreeWayTextMerge.merge(
            base: base, local: base, remote: remote, winner: .local)
        XCTAssertEqual(result, .init(text: remote, hasConflicts: false))
    }

    func testEditsToDifferentLinesAreBothKept() {
        let local = base.replacingOccurrences(of: "아빠 건강검진", with: "아빠 건강검진 결과")
        let remote = base.replacingOccurrences(of: "수련회 준비", with: "수련회 준비팀")
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .local)
        XCTAssertEqual(
            result,
            .init(
                text: """
                    1. 아빠 건강검진 결과
                    2. 동생 수능
                    3. 수련회 준비팀
                    """,
                hasConflicts: false
            )
        )
    }

    func testSameLineEditedDifferentlyTakesWinnerAndReportsConflict() {
        let local = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 평안")
        let remote = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 컨디션")

        let localWins = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .local)
        XCTAssertEqual(localWins, .init(text: local, hasConflicts: true))

        let remoteWins = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .remote)
        XCTAssertEqual(remoteWins, .init(text: remote, hasConflicts: true))
    }

    func testIdenticalEditsOnBothSidesAreNotAConflict() {
        let edited = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 평안")
        let result = ThreeWayTextMerge.merge(
            base: base, local: edited, remote: edited, winner: .remote)
        XCTAssertEqual(result, .init(text: edited, hasConflicts: false))
    }

    func testBothSidesAppendingAtTheEndKeepsBothWinnerFirst() {
        let local = base + "\n4. 엄마 허리"
        let remote = base + "\n4. 교회 이사"
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .remote)
        XCTAssertEqual(
            result,
            .init(text: base + "\n4. 교회 이사\n4. 엄마 허리", hasConflicts: false)
        )
    }

    func testDeletionAndEditOfDifferentLinesAreBothApplied() {
        let local = """
            1. 아빠 건강검진
            3. 수련회 준비
            """
        let remote = base.replacingOccurrences(of: "수련회 준비", with: "수련회 준비팀")
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .local)
        XCTAssertEqual(
            result,
            .init(
                text: """
                    1. 아빠 건강검진
                    3. 수련회 준비팀
                    """,
                hasConflicts: false
            )
        )
    }

    func testDeletionAgainstEditOfTheSameLineIsAConflict() {
        let local = """
            1. 아빠 건강검진
            3. 수련회 준비
            """
        let remote = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 평안")
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .remote)
        XCTAssertEqual(result, .init(text: remote, hasConflicts: true))
    }

    func testTrailingNewlineAndBlankLinesArePreserved() {
        let base = "제목\n\n본문\n"
        let local = "제목\n\n본문 수정\n"
        let remote = "새 제목\n\n본문\n"
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .local)
        XCTAssertEqual(result, .init(text: "새 제목\n\n본문 수정\n", hasConflicts: false))
    }

    func testInsertionNextToTheOtherSidesEditIsNotAConflict() {
        let local = base.replacingOccurrences(of: "2. 동생 수능", with: "1-1. 할머니 병원\n2. 동생 수능")
        let remote = base.replacingOccurrences(of: "동생 수능", with: "동생 수능 평안")
        let result = ThreeWayTextMerge.merge(
            base: base, local: local, remote: remote, winner: .local)
        XCTAssertEqual(
            result,
            .init(
                text: """
                    1. 아빠 건강검진
                    1-1. 할머니 병원
                    2. 동생 수능 평안
                    3. 수련회 준비
                    """,
                hasConflicts: false
            )
        )
    }

    func testEmptyBaseWithDifferentTextKeepsBoth() {
        let result = ThreeWayTextMerge.merge(base: "", local: "가", remote: "나", winner: .local)
        XCTAssertEqual(result, .init(text: "가\n나", hasConflicts: false))
    }
}
#endif
