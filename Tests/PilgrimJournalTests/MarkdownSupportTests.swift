#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
#if os(macOS)
import AppKit
#endif

final class MarkdownSupportTests: XCTestCase {
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

    func testLiveStylingWaitsForAWordBoundary() {
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldScheduleStyling(
                after: "한글",
                cursorUTF16Offset: 2
            )
        )
        XCTAssertFalse(
            MarkdownInputReconciliation.shouldScheduleStyling(
                after: "English",
                cursorUTF16Offset: 7
            )
        )
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldScheduleStyling(
                after: "한글 ",
                cursorUTF16Offset: 3
            )
        )
        XCTAssertTrue(
            MarkdownInputReconciliation.shouldScheduleStyling(
                after: "English\n",
                cursorUTF16Offset: 8
            )
        )
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

    func testBlockMarkdownUsesDistinctLiveEditorTreatments() {
        let markdown = "* 항목\n> 인용\n---\n```swift\nlet value = \"hello\" // note\n```"
        let source = markdown as NSString
        let storage = NSTextStorage(string: markdown)

        LiveMarkdownStyler.apply(to: storage)

        let bulletStyle = storage.attribute(
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
        let quoteStyle = storage.attribute(
            .paragraphStyle,
            at: source.range(of: "인용").location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertFalse(try! XCTUnwrap(quoteStyle).textBlocks.isEmpty)
        let codeLocation = source.range(of: "let value").location
        let codeStyle = storage.attribute(
            .paragraphStyle,
            at: codeLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertFalse(try! XCTUnwrap(codeStyle).textBlocks.isEmpty)
        XCTAssertNotNil(storage.attribute(
            .backgroundColor,
            at: codeLocation,
            effectiveRange: nil
        ))
        let keywordColor = storage.attribute(
            .foregroundColor,
            at: source.range(of: "let").location,
            effectiveRange: nil
        ) as? NSColor
        let identifierColor = storage.attribute(
            .foregroundColor,
            at: source.range(of: "value").location,
            effectiveRange: nil
        ) as? NSColor
        let stringColor = storage.attribute(
            .foregroundColor,
            at: source.range(of: "hello").location,
            effectiveRange: nil
        ) as? NSColor
        let commentColor = storage.attribute(
            .foregroundColor,
            at: source.range(of: "note").location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertNotEqual(keywordColor, identifierColor)
        XCTAssertNotEqual(stringColor, identifierColor)
        XCTAssertNotEqual(commentColor, identifierColor)
        let separatorLocation = source.range(of: "---").location
        let separatorStyle = storage.attribute(
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

        let topStyle = try! XCTUnwrap(storage.attribute(
            .paragraphStyle,
            at: source.range(of: "상위").location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let nestedStyle = try! XCTUnwrap(storage.attribute(
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
            let style = try! XCTUnwrap(storage.attribute(
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
        XCTAssertNil(storage.attribute(
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
        XCTAssertNil(storage.attribute(
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

    func testInlineFormattingWrapsSelectionWithoutChangingSelectedText() {
        let result = MarkdownCommandProcessor.applying(
            .bold,
            to: "오늘의 묵상",
            selection: NSRange(location: 4, length: 2)
        )

        XCTAssertEqual(result.text, "오늘의 **묵상**")
        XCTAssertEqual(result.selectionUTF16Range, NSRange(location: 6, length: 2))
    }

    func testInlineFormattingDoesNotNestTheSameMarkerAroundPreservedSelection() {
        let once = MarkdownCommandProcessor.applying(
            .bold,
            to: "선택",
            selection: NSRange(location: 0, length: 2)
        )
        let twice = MarkdownCommandProcessor.applying(
            .bold,
            to: once.text,
            selection: try! XCTUnwrap(once.selectionUTF16Range)
        )

        XCTAssertEqual(twice.text, "**선택**")
        XCTAssertEqual(twice.selectionUTF16Range, once.selectionUTF16Range)

        let includingMarkers = MarkdownCommandProcessor.applying(
            .bold,
            to: once.text,
            selection: NSRange(location: 0, length: (once.text as NSString).length)
        )
        XCTAssertEqual(includingMarkers.text, "**선택**")
    }

    func testContextualFormatsPreserveAnActiveSelection() {
        let source = "첫 줄\n둘째 줄"
        let selection = NSRange(location: 0, length: (source as NSString).length)

        let italic = MarkdownCommandProcessor.applying(
            .italic,
            to: "선택",
            selection: NSRange(location: 0, length: 2)
        )
        XCTAssertEqual(italic.text, "*선택*")
        XCTAssertEqual(italic.selectionUTF16Range, NSRange(location: 1, length: 2))

        let link = MarkdownCommandProcessor.applying(
            .link,
            to: "선택",
            selection: NSRange(location: 0, length: 2)
        )
        XCTAssertEqual(link.text, "[선택](https://)")
        XCTAssertEqual(link.selectionUTF16Range, NSRange(location: 1, length: 2))

        for format in [
            MarkdownInlineFormat.heading,
            .bullet,
            .quote,
        ] {
            let result = MarkdownCommandProcessor.applying(
                format,
                to: source,
                selection: selection
            )
            XCTAssertNotNil(result.selectionUTF16Range)
            XCTAssertGreaterThan(result.selectionUTF16Range?.length ?? 0, 0)
        }
    }

    func testDayOneInlineFormatsWrapAndPreserveSelection() {
        let formats: [(MarkdownInlineFormat, String, Int)] = [
            (.strikethrough, "~~선택~~", 2),
            (.highlight, "==선택==", 2),
            (.code, "`선택`", 1),
        ]

        for (format, expected, selectionLocation) in formats {
            let result = MarkdownCommandProcessor.applying(
                format,
                to: "선택",
                selection: NSRange(location: 0, length: 2)
            )
            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(
                result.selectionUTF16Range,
                NSRange(location: selectionLocation, length: 2)
            )
        }
    }

    func testSlashQueryFiltersAndReplacementRemovesTypedCommand() {
        XCTAssertEqual(
            MarkdownCommandProcessor.trailingSlashQuery(in: "본문\n/to"),
            "to"
        )

        let result = MarkdownCommandProcessor.replacingTrailingSlashCommand(
            .today,
            in: "본문\n/to",
            today: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(result.text, "본문\n1970-01-01")
        XCTAssertNil(MarkdownCommandProcessor.trailingSlashQuery(in: result.text))
    }

    func testBulletContinuesAfterReturnAndStopsOnEmptyItem() {
        let continued = MarkdownCommandProcessor.continuingBullet(
            in: "* 기도\n",
            cursorUTF16Offset: 5
        )
        XCTAssertEqual(continued.text, "* 기도\n* ")

        let stopped = MarkdownCommandProcessor.continuingBullet(
            in: "* 기도\n* \n",
            cursorUTF16Offset: 8
        )
        XCTAssertEqual(stopped.text, "* 기도\n\n")
    }

    func testNumberedAndChecklistItemsContinueAndStopNaturally() {
        let numbered = MarkdownCommandProcessor.continuingList(
            in: "1. 첫째\n",
            cursorUTF16Offset: ("1. 첫째\n" as NSString).length
        )
        XCTAssertEqual(numbered.text, "1. 첫째\n2. ")

        let checklist = MarkdownCommandProcessor.continuingList(
            in: "- [x] 완료\n",
            cursorUTF16Offset: ("- [x] 완료\n" as NSString).length
        )
        XCTAssertEqual(checklist.text, "- [x] 완료\n- [ ] ")

        let stopped = MarkdownCommandProcessor.continuingList(
            in: "- [ ] \n",
            cursorUTF16Offset: ("- [ ] \n" as NSString).length
        )
        XCTAssertEqual(stopped.text, "\n")
    }

    func testBackspaceAtMarkerBoundaryRemovesWholeMarker() {
        let emptyItem = "- "
        let onEmptyItem = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: emptyItem,
            cursorUTF16Offset: (emptyItem as NSString).length
        )
        XCTAssertEqual(onEmptyItem?.text, "")
        XCTAssertEqual(onEmptyItem?.cursorUTF16Offset, 0)

        let withContent = "- 할 일"
        let markerOffset = 2
        let onContent = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: withContent,
            cursorUTF16Offset: markerOffset
        )
        XCTAssertEqual(onContent?.text, "할 일")
        XCTAssertEqual(onContent?.cursorUTF16Offset, 0)

        let nested = "  * 하위 항목"
        let nestedMarkerOffset = 4
        let onNested = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: nested,
            cursorUTF16Offset: nestedMarkerOffset
        )
        XCTAssertEqual(onNested?.text, "하위 항목")

        let checklist = "- [ ] 확인"
        let checklistMarkerOffset = 6
        let onChecklist = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: checklist,
            cursorUTF16Offset: checklistMarkerOffset
        )
        XCTAssertEqual(onChecklist?.text, "확인")
    }

    func testBackspaceInMiddleOfContentDoesNotRemoveMarker() {
        let source = "- 할 일"
        let midContent = 4
        XCTAssertNil(MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: source,
            cursorUTF16Offset: midContent
        ))

        // A second line's marker must not be affected by a cursor sitting
        // in the middle of a first, unrelated line.
        let multiline = "본문\n- 목록"
        let firstLineOffset = 1
        XCTAssertNil(MarkdownCommandProcessor.removingListMarkerBeforeCursor(
            in: multiline,
            cursorUTF16Offset: firstLineOffset
        ))
    }

    func testTabIndentsAndShiftTabOutdentsListItems() {
        let source = "* 상위\n* 하위"
        let cursor = (source as NSString).length
        let indented = MarkdownCommandProcessor.adjustingListIndentation(
            in: source,
            selection: NSRange(location: cursor, length: 0),
            direction: .indent
        )
        XCTAssertEqual(indented.text, "* 상위\n  * 하위")
        XCTAssertEqual(indented.cursorUTF16Offset, cursor + 2)

        let outdented = MarkdownCommandProcessor.adjustingListIndentation(
            in: indented.text,
            selection: NSRange(
                location: indented.cursorUTF16Offset,
                length: 0
            ),
            direction: .outdent
        )
        XCTAssertEqual(outdented.text, source)
        XCTAssertEqual(outdented.cursorUTF16Offset, cursor)
    }

    func testTabDoesNotIndentPlainParagraphs() {
        let source = "일반 문장"
        let result = MarkdownCommandProcessor.adjustingListIndentation(
            in: source,
            selection: NSRange(location: source.utf16.count, length: 0),
            direction: .indent
        )
        XCTAssertEqual(result.text, source)
    }

    func testExpandedSlashCommandsUseStableMarkdown() {
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/h6 "),
            "###### "
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/checklist "),
            "- [ ] "
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/quote "),
            "> "
        )
    }

    func testHeadingSlashCommandsExpandAtStartOfLine() {
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/h1 "),
            "# "
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "본문\n/h2 "),
            "본문\n## "
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/h3 "),
            "### "
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "본문 /h1 "),
            "본문 /h1 "
        )
    }

    func testTodayAndLineSlashCommandsUseStableMarkdownOutput() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let today = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 27,
            hour: 12
        ))!

        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(
                in: "/today ",
                today: today,
                timeZone: utc
            ),
            "2026-07-27"
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.expandTrailingCommand(in: "/line "),
            "---\n"
        )
        XCTAssertEqual(
            MarkdownCommandProcessor.applying(.line, to: "본문"),
            "본문\n---\n"
        )
    }

    func testSlashCommandExpandsAtCurrentCursorAndPreservesFollowingText() {
        let source = "앞\n/h2 뒤"
        let cursor = ("앞\n/h2 " as NSString).length

        let result = MarkdownCommandProcessor.expandCommand(
            in: source,
            cursorUTF16Offset: cursor
        )

        XCTAssertEqual(result.text, "앞\n## 뒤")
        XCTAssertEqual(result.cursorUTF16Offset, ("앞\n## " as NSString).length)
    }

    func testKeyboardHeadingReplacesExistingHeadingLevel() {
        let source = "## 제목"
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            .heading1,
            to: source,
            selection: NSRange(location: 0, length: source.utf16.count)
        )

        XCTAssertEqual(result.text, "# 제목")
    }

    func testKeyboardNumberedListNumbersSelectedLines() {
        let source = "하나\n둘"
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            .numberedList,
            to: source,
            selection: NSRange(location: 0, length: source.utf16.count)
        )

        XCTAssertEqual(result.text, "1. 하나\n2. 둘")
    }

    func testInsertingAttachmentImageOnEmptyDocumentAddsNoSurroundingNewlines() {
        let id = UUID()
        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            into: "",
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result.text, "![](attachment:\(id.uuidString))")
        XCTAssertEqual(result.cursorUTF16Offset, (result.text as NSString).length)
    }

    func testInsertingAttachmentImageInMiddleOfParagraphForcesSurroundingNewlines() {
        let id = UUID()
        let source = "앞문장 뒷문장"
        let cursor = ("앞문장" as NSString).length

        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            into: source,
            selection: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(result.text, "앞문장\n![](attachment:\(id.uuidString))\n 뒷문장")
    }

    func testInsertingAttachmentImageAtEndOfLineAddsOnlyLeadingNewline() {
        let id = UUID()
        let source = "본문 줄"
        let cursor = (source as NSString).length

        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            into: source,
            selection: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(result.text, "본문 줄\n![](attachment:\(id.uuidString))")
        XCTAssertEqual(result.cursorUTF16Offset, (result.text as NSString).length)
    }

    func testInsertingAttachmentImageAfterExistingNewlineDoesNotDoubleIt() {
        let id = UUID()
        let source = "본문 줄\n"
        let cursor = (source as NSString).length

        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            into: source,
            selection: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(result.text, "본문 줄\n![](attachment:\(id.uuidString))")
    }

    func testDocumentParserRecognizesStandaloneAttachmentImageLineAsImageBlock() {
        let id = UUID()
        let markdown = "본문 앞\n\n![](attachment:\(id.uuidString))\n\n본문 뒤"

        let blocks = MarkdownDocumentParser.parse(markdown)

        XCTAssertTrue(blocks.contains(MarkdownBlock(kind: .image(id), content: "")))
    }

    func testDocumentParserTreatsAttachmentMarkerSharingLineAsParagraphText() {
        let id = UUID()
        let markdown = "앞 ![](attachment:\(id.uuidString)) 뒤"

        let blocks = MarkdownDocumentParser.parse(markdown)

        XCTAssertEqual(blocks, [MarkdownBlock(kind: .paragraph, content: markdown)])
    }

    func testInsertingAttachmentImageWithDisplaySizeAppendsSizeSuffix() {
        let id = UUID()

        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            displaySize: CGSize(width: 400, height: 300.4),
            into: "",
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result.text, "![](attachment:\(id.uuidString) =400x300)")
    }

    func testInsertingAttachmentImageWithoutDisplaySizeMatchesOriginalSyntax() {
        let id = UUID()

        let result = MarkdownCommandProcessor.insertingAttachmentImage(
            id: id,
            into: "",
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result.text, "![](attachment:\(id.uuidString))")
    }

    func testDocumentParserRecognizesSizedAttachmentImageLineAsImageBlockWithSameID() {
        let id = UUID()
        let markdown = "본문 앞\n\n![](attachment:\(id.uuidString) =400x300)\n\n본문 뒤"

        let blocks = MarkdownDocumentParser.parse(markdown)

        XCTAssertTrue(blocks.contains(MarkdownBlock(kind: .image(id), content: "")))
    }

    func testAttachmentImageDecorationParsesIDAndSizeFromSizedMarker() {
        let id = UUID()
        let markdown = "![](attachment:\(id.uuidString) =400x300)"
        let source = markdown as NSString

        let matches = MarkdownAttachmentImageDecoration.matches(in: markdown)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].markerRange, NSRange(location: 0, length: source.length))
        XCTAssertEqual(matches[0].attachmentID, id)
        XCTAssertEqual(matches[0].storedWidth, 400)
        XCTAssertEqual(matches[0].storedHeight, 300)
    }

    func testAttachmentImageDecorationParsesIDWithNilSizeFromUnsizedMarker() {
        let id = UUID()
        let markdown = "![](attachment:\(id.uuidString))"

        let matches = MarkdownAttachmentImageDecoration.matches(in: markdown)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].attachmentID, id)
        XCTAssertNil(matches[0].storedWidth)
        XCTAssertNil(matches[0].storedHeight)
    }

    func testAttachmentImageDecorationIgnoresMarkerSharingLineWithOtherText() {
        let id = UUID()
        let markdown = "앞 ![](attachment:\(id.uuidString) =400x300) 뒤"

        XCTAssertTrue(MarkdownAttachmentImageDecoration.matches(in: markdown).isEmpty)
    }

    func testAttachmentImageDisplaySizeKeepsStoredSizeWhenNarrowerThanContainer() {
        let size = LiveMarkdownStyler.attachmentImageDisplaySize(
            storedWidth: 300, storedHeight: 150, containerWidth: 600
        )

        XCTAssertEqual(size, CGSize(width: 300, height: 150))
    }

    func testAttachmentImageDisplaySizeClampsToContainerWidthPreservingAspectRatio() {
        let size = LiveMarkdownStyler.attachmentImageDisplaySize(
            storedWidth: 1200, storedHeight: 600, containerWidth: 600
        )

        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 300)
    }

    func testAttachmentImageDisplaySizeWithoutStoredSizeFillsContainerWidth() {
        let size = LiveMarkdownStyler.attachmentImageDisplaySize(
            storedWidth: nil, storedHeight: nil, containerWidth: 500
        )

        XCTAssertEqual(size.width, 500)
        XCTAssertEqual(size.height, 300)
    }

    // Typed text that inherits a hidden marker's attributes is stored but
    // never drawn — see the 2026-08-15 entry in docs/known-issues.md.
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
#endif
