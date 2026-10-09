#if canImport(XCTest)
@testable import PilgrimJournal
import SwiftUI
import XCTest

final class FocusModeLayoutPolicyTests: XCTestCase {
    func testFocusModeUsesDoubleColumnBecauseMacIgnoresDetailOnly() {
        XCTAssertEqual(FocusModeLayoutPolicy.visibility(isFocusMode: true), .doubleColumn)
        XCTAssertEqual(FocusModeLayoutPolicy.visibility(isFocusMode: false), .all)
    }

    func testWriteBacksWhileFocusedAreUndoneNotTreatedAsExit() {
        // SwiftUI can consider `.automatic` equal to `.doubleColumn` on macOS.
        // Only explicit layouts different from the focused layout must be reset.
        for visibility in [NavigationSplitViewVisibility.all, .detailOnly] {
            XCTAssertTrue(
                FocusModeLayoutPolicy.shouldReassert(isFocusMode: true, visibility: visibility)
            )
        }
        XCTAssertFalse(
            FocusModeLayoutPolicy.shouldReassert(isFocusMode: true, visibility: .doubleColumn)
        )
    }

    func testNothingIsReassertedOutsideFocusMode() {
        for visibility in [NavigationSplitViewVisibility.all, .doubleColumn, .detailOnly] {
            XCTAssertFalse(
                FocusModeLayoutPolicy.shouldReassert(isFocusMode: false, visibility: visibility)
            )
        }
    }
}
#endif
