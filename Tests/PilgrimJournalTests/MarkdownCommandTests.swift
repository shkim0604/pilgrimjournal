#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MarkdownSupportTests {
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
        XCTAssertNil(
            MarkdownCommandProcessor.removingListMarkerBeforeCursor(
                in: source,
                cursorUTF16Offset: midContent
            ))

        // A second line's marker must not be affected by a cursor sitting
        // in the middle of a first, unrelated line.
        let multiline = "본문\n- 목록"
        let firstLineOffset = 1
        XCTAssertNil(
            MarkdownCommandProcessor.removingListMarkerBeforeCursor(
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
            expandedAtEnd(in: "/h6 "),
            "###### "
        )
        XCTAssertEqual(
            expandedAtEnd(in: "/checklist "),
            "- [ ] "
        )
        XCTAssertEqual(
            expandedAtEnd(in: "/quote "),
            "> "
        )
    }

    func testHeadingSlashCommandsExpandAtStartOfLine() {
        XCTAssertEqual(
            expandedAtEnd(in: "/h1 "),
            "# "
        )
        XCTAssertEqual(
            expandedAtEnd(in: "본문\n/h2 "),
            "본문\n## "
        )
        XCTAssertEqual(
            expandedAtEnd(in: "/h3 "),
            "### "
        )
        XCTAssertEqual(
            expandedAtEnd(in: "본문 /h1 "),
            "본문 /h1 "
        )
    }

    func testTodayAndLineSlashCommandsUseStableMarkdownOutput() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let today = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 27,
                hour: 12
            ))!

        XCTAssertEqual(
            expandedAtEnd(
                in: "/today ",
                today: today,
                timeZone: utc
            ),
            "2026-07-27"
        )
        XCTAssertEqual(
            expandedAtEnd(in: "/line "),
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

    func testRevealedInlineSpansFollowCaretAndSelection() {
        let markdown = "가 ~~취소~~ 나\n**굵게**"
        let source = markdown as NSString
        let strike = source.range(of: "~~취소~~")
        let bold = source.range(of: "**굵게**")

        func spans(_ location: Int, _ length: Int = 0) -> Set<NSRange> {
            LiveMarkdownStyler.revealedInlineSpans(
                in: markdown, selection: NSRange(location: location, length: length))
        }
        // Caret right before the opening and right after the closing marker
        // both count; one character outside does not.
        XCTAssertEqual(spans(strike.location), [strike])
        XCTAssertEqual(spans(NSMaxRange(strike)), [strike])
        XCTAssertEqual(spans(strike.location - 1), [])
        XCTAssertEqual(spans(NSMaxRange(strike) + 1), [])
        XCTAssertEqual(spans(bold.location + 3), [bold])
        // A selection spanning both lines reveals both.
        XCTAssertEqual(
            spans(strike.location + 3, NSMaxRange(bold) - strike.location - 3), [strike, bold])
        XCTAssertEqual(
            LiveMarkdownStyler.revealedInlineSpans(in: markdown, selection: nil), [])
    }

    func testStrikethroughKeyboardCommandWrapsSelection() {
        let source = "앞 취소 뒤"
        let selection = (source as NSString).range(of: "취소")
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            .strikethrough,
            to: source,
            selection: selection
        )

        XCTAssertEqual(result.text, "앞 ~~취소~~ 뒤")
        XCTAssertEqual(
            result.selectionUTF16Range,
            NSRange(location: selection.location + 2, length: selection.length)
        )
        XCTAssertTrue(MarkdownInlineFormat.contextualCases.contains(.strikethrough))
    }
}

/// Expands a slash command typed at the very end of `text`.
private func expandedAtEnd(
    in text: String,
    today: Date = .now,
    timeZone: TimeZone = .current
) -> String {
    MarkdownCommandProcessor.expandCommand(
        in: text,
        cursorUTF16Offset: text.utf16.count,
        today: today,
        timeZone: timeZone
    ).text
}

#endif
