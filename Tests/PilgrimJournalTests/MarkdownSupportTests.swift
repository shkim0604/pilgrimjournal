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
            MarkdownBulletDecoration.ranges(in: markdown),
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
    #endif

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
}
#endif
