#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A reload (kind move) that arrives mid-composition is held back until the
/// composition ends; these cover how the composed characters are carried over.
final class ExternalTextRebaseTests: XCTestCase {
    private let details = "\n\n- 성경 구절: 시편 23편"

    func testCompositionAtTheEndKeepsTheAppendedDetailLines() {
        // "가" was still marked when the reload appended the detail lines;
        // the composition then committed "각".
        let result = ExternalTextRebase.rebase(
            local: "오늘 기도각",
            base: "오늘 기도가",
            incoming: "오늘 기도가" + details,
            localCursorUTF16Offset: 6
        )
        XCTAssertEqual(result.text, "오늘 기도각" + details)
        XCTAssertEqual(result.cursorUTF16Offset, 6)
    }

    func testCompositionBeforeTheReloadedChangeKeepsBoth() {
        let result = ExternalTextRebase.rebase(
            local: "첫 줄 한\n둘째 줄",
            base: "첫 줄 하\n둘째 줄",
            incoming: "첫 줄 하\n둘째 줄" + details,
            localCursorUTF16Offset: 5
        )
        XCTAssertEqual(result.text, "첫 줄 한\n둘째 줄" + details)
        XCTAssertEqual(result.cursorUTF16Offset, 5)
    }

    func testCompositionAfterAReloadedInsertionShiftsWithIt() {
        let result = ExternalTextRebase.rebase(
            local: "머리\n본문 끝맺",
            base: "머리\n본문 끝마",
            incoming: "새 줄\n머리\n본문 끝마",
            localCursorUTF16Offset: 8
        )
        XCTAssertEqual(result.text, "새 줄\n머리\n본문 끝맺")
        XCTAssertEqual(result.cursorUTF16Offset, 12)
    }

    func testOverlappingEditsKeepTheReload() {
        let result = ExternalTextRebase.rebase(
            local: "가너다",
            base: "가나다",
            incoming: "가X다",
            localCursorUTF16Offset: 2
        )
        XCTAssertEqual(result.text, "가X다")
        XCTAssertEqual(result.cursorUTF16Offset, 2)
    }

    func testNothingTypedTakesTheReloadAndMovesTheCaretPastItsInsertion() {
        let atEnd = ExternalTextRebase.rebase(
            local: "본문", base: "본문", incoming: "본문" + details, localCursorUTF16Offset: 2)
        XCTAssertEqual(atEnd.text, "본문" + details)
        XCTAssertEqual(atEnd.cursorUTF16Offset, 2)

        let afterInsertion = ExternalTextRebase.rebase(
            local: "본문", base: "본문", incoming: "앞\n본문", localCursorUTF16Offset: 2)
        XCTAssertEqual(afterInsertion.cursorUTF16Offset, 4)
    }

    func testEditsNeverSplitASurrogatePair() {
        // 😀 and 😃 share their lead surrogate.
        let result = ExternalTextRebase.rebase(
            local: "a😃",
            base: "a😀",
            incoming: "a😀" + details,
            localCursorUTF16Offset: 3
        )
        XCTAssertEqual(result.text, "a😃" + details)
        XCTAssertEqual(result.cursorUTF16Offset, 3)
    }
}

#endif
