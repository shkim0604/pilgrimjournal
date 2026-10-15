#if canImport(XCTest)
@testable import PilgrimJournal
import XCTest

final class EntryEditorFocusLayoutTests: XCTestCase {
    func testNormalLayoutShowsEverythingAroundTheBody() {
        let layout = EntryEditorFocusLayout(isFocusMode: false, saveState: .saved)
        XCTAssertTrue(layout.showsNavigationBar)
        XCTAssertTrue(layout.showsEntryDetails)
        XCTAssertTrue(layout.showsMarkdownChrome)
        XCTAssertFalse(layout.showsExitButton)
        XCTAssertFalse(layout.showsSaveFailure)
    }

    func testFocusModeLeavesOnlyTitleBodyAndTheWayOut() {
        let layout = EntryEditorFocusLayout(isFocusMode: true, saveState: .saved)
        XCTAssertFalse(layout.showsNavigationBar)
        XCTAssertFalse(layout.showsEntryDetails)
        XCTAssertFalse(layout.showsMarkdownChrome)
        XCTAssertTrue(layout.showsExitButton)
        XCTAssertFalse(layout.showsSaveFailure)
    }

    func testSavingIsNotSurfacedInFocusMode() {
        let layout = EntryEditorFocusLayout(isFocusMode: true, saveState: .saving)
        XCTAssertFalse(layout.showsSaveFailure)
    }

    func testFailedSaveStaysVisibleWhenTheStatusPillIsHidden() {
        XCTAssertTrue(
            EntryEditorFocusLayout(isFocusMode: true, saveState: .failed("x"))
                .showsSaveFailure
        )
        // Outside focus mode the status pill and the footer's 다시 저장 cover it.
        XCTAssertFalse(
            EntryEditorFocusLayout(isFocusMode: false, saveState: .failed("x"))
                .showsSaveFailure
        )
    }
}
#endif
