#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MarkdownSupportTests {
    func testInlineMarkdownStylesWithoutTrailingWhitespace() {
        for text in [
            "**굵게**", "_기울임_", "~~취소~~", "==강조==",
            "`code`", "[링크](https://example.com)", "```",
        ] {
            XCTAssertTrue(
                MarkdownInputReconciliation.shouldStyleImmediately(
                    after: text, cursorUTF16Offset: text.utf16.count
                ), text)
        }
    }

    func testOrdinaryTypingUsesDeferredStyling() {
        for text in ["한글", "English", "본문 ", "문장\n", "😀", ""] {
            XCTAssertFalse(
                MarkdownInputReconciliation.shouldStyleImmediately(
                    after: text, cursorUTF16Offset: text.utf16.count
                ), text)
        }
    }

    func testImmediateStylingUsesCaretInsteadOfDocumentEnd() {
        let prefix = "😀 **굵게**"
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldStyleImmediately(
                after: prefix + " 뒤 문장", cursorUTF16Offset: prefix.utf16.count
            ))
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldStyleImmediately(
                after: "text", cursorUTF16Offset: 99
            ))
    }

    func testDayOneEscapesArePresentationOnlyAndKeepStoredMarkdown() {
        let markdown = #"문장입니다\. 다음은 \*별표\*입니다."#

        XCTAssertEqual(
            MarkdownEscaping.unescaped(markdown),
            "문장입니다. 다음은 *별표*입니다."
        )
        XCTAssertEqual(MarkdownEscaping.markerRanges(in: markdown).count, 3)
        XCTAssertEqual(markdown, #"문장입니다\. 다음은 \*별표\*입니다."#)
    }

    #if os(macOS)
    func testDayOneEscapeMarkerIsHiddenUntilCursorTouchesIt() {
        let markdown = #"문장입니다\."#
        let marker = try! XCTUnwrap(
            MarkdownEscaping.markerRanges(in: markdown).first
        )
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)
        XCTAssertEqual(storage.string, markdown)
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: marker.location,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )

        LiveMarkdownStyler.apply(
            to: storage,
            revealing: NSRange(location: marker.location + 1, length: 0)
        )
        XCTAssertNotEqual(
            storage.attribute(
                .foregroundColor,
                at: marker.location,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )
        XCTAssertEqual(storage.string, markdown)
    }

    func testStrikethroughIsDrawnInLiveEditor() {
        for markdown in ["~~취소~~", "앞 ~~취소~~ 뒤", "* ~~취소~~", "# ~~취소~~", "> ~~취소~~"] {
            let source = markdown as NSString
            let storage = NSTextStorage(string: markdown)
            LiveMarkdownStyler.apply(to: storage)
            XCTAssertEqual(
                storage.attribute(
                    .strikethroughStyle,
                    at: source.range(of: "취소").location,
                    effectiveRange: nil
                ) as? Int,
                NSUnderlineStyle.single.rawValue,
                markdown
            )
        }
    }

    func testInlineMarkersAreHiddenUntilCaretTouchesTheirSpan() {
        let markdown = "앞 **굵게** ~~취소~~ 뒤"
        let source = markdown as NSString
        let boldMarker = source.range(of: "**").location
        let strikeMarker = source.range(of: "~~").location
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)
        for location in [boldMarker, strikeMarker] {
            XCTAssertEqual(
                storage.attribute(.foregroundColor, at: location, effectiveRange: nil)
                    as? NSColor,
                .clear
            )
        }

        // Caret just inside the bold span: only its markers come back, dimmed.
        LiveMarkdownStyler.apply(
            to: storage,
            revealing: NSRange(location: boldMarker + 3, length: 0)
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: boldMarker, effectiveRange: nil)
                as? NSColor,
            .tertiaryLabelColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: strikeMarker, effectiveRange: nil)
                as? NSColor,
            .clear
        )
        XCTAssertEqual(storage.string, markdown)
    }

    func testBlockMarkdownUsesDistinctLiveEditorTreatments() {
        let markdown = "* 항목\n> 인용\n---\n```swift\nlet value = \"hello\" // note\n```"
        let source = markdown as NSString
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)

        let bulletStyle =
            storage.attribute(
                .paragraphStyle,
                at: source.range(of: "항목").location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        XCTAssertLessThan(
            try! XCTUnwrap(bulletStyle).firstLineHeadIndent,
            try! XCTUnwrap(bulletStyle).headIndent
        )
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "*").location,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )
        XCTAssertEqual(
            MarkdownBulletDecoration.matches(in: markdown).map(\.markerRange),
            [source.range(of: "*")]
        )
        let quoteStyle =
            storage.attribute(
                .paragraphStyle,
                at: source.range(of: "인용").location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        XCTAssertFalse(try! XCTUnwrap(quoteStyle).textBlocks.isEmpty)
        let codeLocation = source.range(of: "let value").location
        let codeStyle =
            storage.attribute(
                .paragraphStyle,
                at: codeLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        XCTAssertFalse(try! XCTUnwrap(codeStyle).textBlocks.isEmpty)
        XCTAssertNotNil(
            storage.attribute(
                .backgroundColor,
                at: codeLocation,
                effectiveRange: nil
            ))
        let keywordColor =
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "let").location,
                effectiveRange: nil
            ) as? NSColor
        let identifierColor =
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "value").location,
                effectiveRange: nil
            ) as? NSColor
        let stringColor =
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "hello").location,
                effectiveRange: nil
            ) as? NSColor
        let commentColor =
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "note").location,
                effectiveRange: nil
            ) as? NSColor
        XCTAssertNotEqual(keywordColor, identifierColor)
        XCTAssertNotEqual(stringColor, identifierColor)
        XCTAssertNotEqual(commentColor, identifierColor)
        let separatorLocation = source.range(of: "---").location
        let separatorStyle =
            storage.attribute(
                .paragraphStyle,
                at: separatorLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        XCTAssertEqual(separatorStyle?.minimumLineHeight, 20)
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: separatorLocation,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )
        XCTAssertEqual(storage.string, markdown)
    }

    func testNestedBulletsGetHigherIndentationLevel() {
        let markdown = "* 상위\n  * 하위\n    * 더 하위"
        let source = markdown as NSString

        let matches = MarkdownBulletDecoration.matches(in: markdown)

        XCTAssertEqual(matches.map(\.indentationLevel), [0, 1, 2])
        XCTAssertEqual(matches[0].markerRange, source.range(of: "*"))
    }

    func testNestedBulletWrapIndentGrowsWithLevel() {
        let markdown = "* 상위\n  * 하위"
        let source = markdown as NSString
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)

        let topStyle = try! XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: source.range(of: "상위").location,
                effectiveRange: nil
            ) as? NSParagraphStyle)
        let nestedStyle = try! XCTUnwrap(
            storage.attribute(
                .paragraphStyle,
                at: source.range(of: "하위").location,
                effectiveRange: nil
            ) as? NSParagraphStyle)

        // A wrapped continuation line under the nested bullet must indent
        // further than one under the top-level bullet, or it lands back at
        // the top-level column instead of under its own marker.
        XCTAssertGreaterThan(nestedStyle.headIndent, topStyle.headIndent)
        // Deeper levels also get more first-line margin, on top of the
        // source text's own 2-space-per-level indent — otherwise nesting
        // reads as too subtle to see.
        XCTAssertGreaterThan(nestedStyle.firstLineHeadIndent, topStyle.firstLineHeadIndent)
    }

    func testWrappedBulletLineAlignsWithFirstLinesTextStart() {
        // Regression test for a real bug: a wrapped continuation line
        // landed to the right of where the first line's visible text
        // (after the hidden "- " marker) actually starts, at every
        // indentation level — headIndent must never exceed
        // firstLineHeadIndent by more than roughly one marker's width.
        for markdown in ["* 최상위 항목", "  * 중첩 항목", "    * 더 중첩된 항목"] {
            let storage = NSTextStorage(string: markdown)
            LiveMarkdownStyler.apply(to: storage)
            let style = try! XCTUnwrap(
                storage.attribute(
                    .paragraphStyle, at: 0, effectiveRange: nil
                ) as? NSParagraphStyle)

            // The wrapped line must land at or after the first line's own
            // margin (never to its left — text would look mis-nested)...
            XCTAssertGreaterThanOrEqual(style.headIndent, style.firstLineHeadIndent)
            // ...and reasonably close to it — the old formula left roughly
            // an extra 16pt gap (20 vs. 2 at level 0) that isn't explained
            // by the hidden marker's own width, which reads as clearly
            // misaligned. A single "- " marker plus its kern gap is well
            // under 30pt at any standard body text size.
            XCTAssertLessThan(style.headIndent - style.firstLineHeadIndent, 30)
        }
    }

    func testChecklistMarkerAndBracketsAreHiddenNotAttachmentBased() {
        let markdown = "- [ ] 할 일\n- [x] 완료된 일"
        let source = markdown as NSString
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)

        // The checkbox is drawn by MarkdownChecklistDecoration, not an
        // NSTextAttachment (see the comment at the checklist regex) — the
        // marker and brackets must just be invisible, not replaced.
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "-", options: [], range: NSRange(location: 0, length: 5))
                    .location,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )
        XCTAssertNil(
            storage.attribute(
                .attachment,
                at: 0,
                effectiveRange: nil
            ))
        XCTAssertEqual(
            storage.attribute(
                .foregroundColor,
                at: source.range(of: "[ ]").location,
                effectiveRange: nil
            ) as? NSColor,
            .clear
        )
        let uncheckedContentLocation = source.range(of: "할 일").location
        XCTAssertNil(
            storage.attribute(
                .strikethroughStyle,
                at: uncheckedContentLocation,
                effectiveRange: nil
            ))
        let checkedContentLocation = source.range(of: "완료된 일").location
        XCTAssertEqual(
            storage.attribute(
                .strikethroughStyle,
                at: checkedContentLocation,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(storage.string, markdown)
    }
    #endif

    func testChecklistDecorationLocatesMarkerAndCheckedState() {
        let markdown = "- [ ] 할 일\n  * [X] 완료\n- 그냥 불릿"
        let source = markdown as NSString

        let matches = MarkdownChecklistDecoration.matches(in: markdown)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].markerRange, source.range(of: "-"))
        XCTAssertFalse(matches[0].checked)
        XCTAssertEqual(
            matches[1].markerRange,
            source.range(of: "*", options: [], range: NSRange(location: 10, length: 10))
        )
        XCTAssertTrue(matches[1].checked)
    }
}

#endif
