#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MarkdownSupportTests {
    func testIMECompositionDefersTextStorageMutation() {
        XCTAssertFalse(
            MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: true
            )
        )
        XCTAssertTrue(
            MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: false
            )
        )
    }

    /// Builds the history the way the editor does, one publish per keystroke.
    private func publishedHistory(_ values: [String]) -> [Int] {
        var history: [Int] = []
        for value in values {
            MarkdownInputReconciliation.recordPublishedText(value, in: &history)
        }
        return history
    }

    func testStaleBindingEchoDoesNotOverwriteNewerTyping() {
        // The user typed "가" and then "가나". SwiftUI renders the first value
        // and delivers it after the second keystroke already reached the text
        // view. Applying it would drop "나".
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldApplyExternalText(
                incoming: "가",
                current: "가나",
                publishedHistory: publishedHistory(["가", "가나"])
            )
        )
    }

    func testExternalTextChangeIsStillApplied() {
        // A toolbar command or a revision restore produces a value the editor
        // never published, so it must reach the text view.
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldApplyExternalText(
                incoming: "# 제목",
                current: "가나",
                publishedHistory: publishedHistory(["가", "가나"])
            )
        )
    }

    func testTextViewAlreadyMatchingTheBindingNeedsNoUpdate() {
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldApplyExternalText(
                incoming: "가나",
                current: "가나",
                publishedHistory: publishedHistory(["가", "가나"])
            )
        )
    }

    func testPublishedHistoryIsBoundedAndKeepsTheNewestValues() {
        var history: [Int] = []
        for index in 0..<200 {
            MarkdownInputReconciliation.recordPublishedText(
                "value-\(index)",
                in: &history
            )
        }

        XCTAssertLessThanOrEqual(
            history.count,
            MarkdownInputReconciliation.publishedHistoryLimit
        )
        XCTAssertEqual(
            history.last,
            MarkdownInputReconciliation.publishedFingerprint("value-199")
        )
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldApplyExternalText(
                incoming: "value-199",
                current: "value-200",
                publishedHistory: history
            )
        )
        // The oldest entries fall out of the window and read as external again.
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldApplyExternalText(
                incoming: "value-0",
                current: "value-200",
                publishedHistory: history
            )
        )
    }
}

#endif
