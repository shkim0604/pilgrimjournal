#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MarkdownSupportTests {
    #if os(macOS)
    /// Typed text has to carry the size the styler would give it, or a
    /// heading types at body size and only snaps to its real size when
    /// something else triggers a restyle. Comparing against `apply`'s own
    /// output keeps the two from drifting apart.
    ///
    /// Point size rather than font equality: AppKit substitutes the concrete
    /// face for Korean text, so the styled run reports Apple SD Gothic Neo
    /// where the typing attributes still hold the system font.
    func testHeadingsAreTypedAtTheSizeTheStylerWouldApply() {
        for level in 1...6 {
            let marker = String(repeating: "#", count: level) + " "
            let storage = NSTextStorage(string: marker + "제목")
            LiveMarkdownStyler.apply(to: storage)
            let styled =
                (storage.attributes(
                    at: (marker as NSString).length, effectiveRange: nil
                )[.font] as? NSFont)?.pointSize

            let typed =
                (LiveMarkdownStyler.typingAttributes(
                    forLinePrefix: marker
                )[.font] as? NSFont)?.pointSize

            XCTAssertEqual(typed, styled, "level \(level) types at the wrong size")
        }
    }

    func testOrdinaryLinesAreTypedAtBodySize() {
        let body = (LiveMarkdownStyler.baseAttributes[.font] as? NSFont)?
            .pointSize
        for prefix in ["", "본문", "#제목", "#", "- ", "> ", "####### "] {
            XCTAssertEqual(
                (LiveMarkdownStyler.typingAttributes(
                    forLinePrefix: prefix
                )[.font] as? NSFont)?.pointSize,
                body,
                "\(prefix.debugDescription) should type at body size"
            )
        }
    }
    #endif

    // Tapping the drawn box is the only practical way to check an item — the
    // `- [x]` source is hidden behind the box.
    func testTogglingAChecklistItemFlipsOnlyThatItemsState() {
        let text = "- [ ] 첫째\n- [x] 둘째\n- [ ] 셋째"
        let matches = MarkdownChecklistDecoration.matches(in: text)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map(\.checked), [false, true, false])

        XCTAssertEqual(
            toggled(matches[0], in: text),
            "- [x] 첫째\n- [x] 둘째\n- [ ] 셋째"
        )
        XCTAssertEqual(
            toggled(matches[1], in: text),
            "- [ ] 첫째\n- [ ] 둘째\n- [ ] 셋째"
        )
    }

    func testTogglingIsReversibleAndPreservesIndentationAndMarker() throws {
        let text = "  * [X] 들여쓴 항목"
        let match = try XCTUnwrap(
            MarkdownChecklistDecoration.matches(in: text).first
        )
        let unchecked = toggled(match, in: text)

        XCTAssertEqual(unchecked, "  * [ ] 들여쓴 항목")
        XCTAssertEqual(
            toggled(
                try XCTUnwrap(MarkdownChecklistDecoration.matches(in: unchecked).first),
                in: unchecked
            ),
            "  * [x] 들여쓴 항목"
        )
    }

    func testLineTextStopsAtTheLineTheCursorIsOn() {
        let text = "첫 줄\n# 제목\n셋째"
        let secondLineStart = ("첫 줄\n" as NSString).length

        XCTAssertEqual(
            MarkdownInputReconciliation.lineText(
                in: text, upTo: secondLineStart + 2
            ),
            "# "
        )
        XCTAssertEqual(
            MarkdownInputReconciliation.lineText(in: text, upTo: 0),
            ""
        )
    }

    func testCompletingABlockMarkerStylesOnThatKeystroke() {
        for line in [
            "# ", "###### ", "- ", "* ", "- [ ] ", "- [x] ", "> ",
            "---", "***", "___", "  - ", "\t# ",
        ] {
            XCTAssertTrue(
                MarkdownInputReconciliation.completesBlockMarker(
                    in: line, cursorUTF16Offset: (line as NSString).length
                ),
                "\(line.debugDescription) should restyle immediately"
            )
        }
        // Also on a later line, not just the first.
        XCTAssertTrue(
            MarkdownInputReconciliation.completesBlockMarker(
                in: "본문\n## ", cursorUTF16Offset: 6
            )
        )
    }

    func testIncompleteOrOrdinaryTextDoesNotStyleEagerly() {
        for (text, cursor) in [
            ("#", 1), // no space yet
            ("#제목", 4), // no space at all — not a heading
            ("# 제목", 5), // heading already styled; keep the debounce
            ("-", 1),
            ("--", 2),
            ("본문 ", 4),
            ("", 0),
            ("####### ", 8), // seven hashes is not a heading
        ] {
            XCTAssertFalse(
                MarkdownInputReconciliation.completesBlockMarker(
                    in: text, cursorUTF16Offset: cursor
                ),
                "\(text.debugDescription) should not restyle eagerly"
            )
        }
    }

    // Typed text that inherits a hidden marker's attributes is stored but
    // never drawn — see "숨긴 마커 뒤 입력과 원자적 이미지 줄" in docs/known-issues.md.
    func testTypingAttributesAreRestoredWhenInheritedFromAHiddenMarker() {
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: 0.1, foregroundAlpha: 0
            )
        )
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: 0.1, foregroundAlpha: 1
            )
        )
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: 13, foregroundAlpha: 0
            )
        )
    }

    func testTypingAttributesAreLeftAloneForOrdinaryText() {
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: 13, foregroundAlpha: 0.8
            )
        )
        // Headings type at a larger size; nothing here may disturb them.
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: 28, foregroundAlpha: 1
            )
        )
        // Missing attributes mean the platform default, which is visible.
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                fontPointSize: nil, foregroundAlpha: nil
            )
        )
    }

    #if os(macOS)
    /// The marker attributes the styler actually produces must be recognised
    /// as hidden — if the styler ever changes how it hides markers, this
    /// fails rather than silently letting typed text go invisible again.
    func testStylerHiddenMarkerAttributesAreDetectedAsNeedingRestore() {
        for markdown in [
            "# 제목",
            "![](attachment:11111111-1111-1111-1111-111111111111)",
        ] {
            let storage = NSTextStorage(string: markdown)
            LiveMarkdownStyler.apply(to: storage)
            let attrs = storage.attributes(at: 0, effectiveRange: nil)

            XCTAssertTrue(
                MarkdownInputReconciliation.shouldRestoreTypingAttributes(
                    fontPointSize: (attrs[.font] as? NSFont)?.pointSize,
                    foregroundAlpha: (attrs[.foregroundColor] as? NSColor)?
                        .usingColorSpace(.deviceRGB)?.alphaComponent
                ),
                "hidden marker of \(markdown.debugDescription) not detected"
            )
        }
    }
    #endif
}

/// Flips one checklist item the way both live editors do: one character, in place.
private func toggled(_ match: MarkdownChecklistDecoration.Match, in text: String) -> String {
    (text as NSString).replacingCharacters(in: match.stateRange, with: match.toggledState)
}

#endif
