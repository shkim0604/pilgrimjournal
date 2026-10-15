#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

final class MarkdownSupportTests: XCTestCase {
    // Every pattern is a literal compiled once into a static; touching them all
    // here turns a typo into a test failure instead of a crash on first use.
    // Two spaces or one tab per nesting level; a stray odd space rounds down.
    func testIndentationLevelCountsTabsAsTwoSpaces() {
        XCTAssertEqual(MarkdownIndentation.level(of: ""), 0)
        XCTAssertEqual(MarkdownIndentation.level(of: " "), 0)
        XCTAssertEqual(MarkdownIndentation.level(of: "  "), 1)
        XCTAssertEqual(MarkdownIndentation.level(of: "\t"), 1)
        XCTAssertEqual(MarkdownIndentation.level(of: "   "), 1)
        XCTAssertEqual(MarkdownIndentation.level(of: "\t  "), 2)
    }

    func testEveryEditorPatternCompiles() {
        XCTAssertEqual(MarkdownPatterns.all.count, 23)
        XCTAssertEqual(EntrySummaryPatterns.replacements.count, 14)
    }

    #if os(macOS)
    @MainActor
    func testNativeDelegateStylesInlineMarkdownOnClosingDelimiter() throws {
        let view = NSTextView()
        view.string = "**굵게**"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        let editor = LiveMarkdownTextEditor(
            text: .constant(view.string),
            selection: .constant(view.selectedRange()),
            autoFocus: false,
            textScale: 1
        )
        let coordinator = editor.makeCoordinator()
        coordinator.textView = view
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

        let font = try XCTUnwrap(
            view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(view.string, "**굵게**")
        XCTAssertEqual(view.selectedRange().location, view.string.utf16.count)
    }

    @MainActor
    func testNativeDelegateRestylesAfterDeletingClosingDelimiter() async throws {
        let view = NSTextView()
        view.string = "**bold**"
        LiveMarkdownStyler.apply(to: view.textStorage!)
        view.textStorage?.deleteCharacters(in: NSRange(location: 6, length: 2))
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let editor = LiveMarkdownTextEditor(
            text: .constant(view.string),
            selection: .constant(view.selectedRange()),
            autoFocus: false,
            textScale: 1
        )
        let coordinator = editor.makeCoordinator()
        coordinator.textView = view
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

        // Restyling is debounced. Wait for it by condition rather than a fixed
        // sleep, which failed under load, and keep the coordinator alive: the
        // scheduled task only holds it weakly.
        func isBold() -> Bool {
            guard
                let font = view.textStorage?.attribute(.font, at: 2, effectiveRange: nil)
                    as? NSFont
            else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while isBold(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        withExtendedLifetime(coordinator) {}

        XCTAssertFalse(isBold())
        XCTAssertEqual(view.string, "**bold")
        XCTAssertEqual(view.selectedRange().location, 6)
    }

    // The editor is magnified (text size), so the visible width is the frame
    // width divided by the zoom. SwiftUI hosts it with Auto Layout, whose engine
    // sizes the text view to the clip view's frame, not its visible bounds.
    // Lines must still wrap at the visible edge: when the editor first appears,
    // when the window shrinks or grows, and when the text size changes.
    @MainActor
    func testEditorTextWrapsAtTheVisibleWidthThroughResizeAndZoom() {
        let (scrollView, textView) = LiveMarkdownTextEditor.makeEditorViews(textScale: 1.15)
        textView.string = String(repeating: "좋은 문장 mixes Korean and English. ", count: 30)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: host.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        func assertWrapsAtVisibleWidth(_ step: String, line: UInt = #line) {
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                textView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 1,
                "text view wider or narrower than the visible area after \(step)",
                line: line
            )
            XCTAssertEqual(
                scrollView.contentView.bounds.origin.x, 0, accuracy: 0.5,
                "scrolled sideways after \(step)", line: line)
        }

        assertWrapsAtVisibleWidth("first layout")
        host.setFrameSize(NSSize(width: 420, height: 400))
        assertWrapsAtVisibleWidth("shrinking")
        host.setFrameSize(NSSize(width: 900, height: 400))
        assertWrapsAtVisibleWidth("growing")
        scrollView.magnification = 1.4
        assertWrapsAtVisibleWidth("zooming in")
        scrollView.magnification = 0.8
        assertWrapsAtVisibleWidth("zooming out")
        host.setFrameSize(NSSize(width: 500, height: 400))
        assertWrapsAtVisibleWidth("shrinking while zoomed out")
    }
    #endif

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

    // The preview must agree with the live editor, which only draws an image
    // for an exact marker with an optional " =WIDTHxHEIGHT" suffix.
    func testDocumentParserTreatsAttachmentMarkerWithUnknownSuffixAsText() {
        let id = UUID()
        let markdown = "![](attachment:\(id.uuidString) 캡션)"

        let blocks = MarkdownDocumentParser.parse(markdown)

        XCTAssertEqual(blocks, [MarkdownBlock(kind: .paragraph, content: markdown)])
        XCTAssertTrue(MarkdownAttachmentImageDecoration.matches(in: markdown).isEmpty)
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

    // An image line has to stay exactly `![](attachment:id …)` or the marker
    // stops matching and the picture is replaced by its raw markdown, so a
    // keystroke landing on that line is given a line of its own.
    private static let imageMarker =
        "![](attachment:11111111-1111-1111-1111-111111111111)"

    func testTypingAtTheEndOfAnImageLineMovesBelowTheImage() {
        let marker = Self.imageMarker
        let end = (marker as NSString).length

        let relocation = MarkdownAttachmentImageDecoration.insertionRelocation(
            in: marker, cursorUTF16Offset: end
        )

        XCTAssertEqual(
            relocation,
            .init(newlineOffset: end, caretOffset: end + 1)
        )
    }

    func testTypingAtTheStartOfAnImageLineMovesAboveTheImage() {
        let relocation = MarkdownAttachmentImageDecoration.insertionRelocation(
            in: Self.imageMarker, cursorUTF16Offset: 0
        )

        XCTAssertEqual(relocation, .init(newlineOffset: 0, caretOffset: 0))
    }

    func testTypingInsideAnImageMarkerMovesBelowTheImage() {
        let marker = Self.imageMarker
        let end = (marker as NSString).length

        let relocation = MarkdownAttachmentImageDecoration.insertionRelocation(
            in: marker, cursorUTF16Offset: 5
        )

        XCTAssertEqual(
            relocation,
            .init(newlineOffset: end, caretOffset: end + 1)
        )
    }

    func testTypingOnAnImageLineAmongOtherLinesUsesThatLinesBounds() {
        let text = "위\n\(Self.imageMarker)\n아래"
        let markerStart = ("위\n" as NSString).length
        let markerEnd = markerStart + (Self.imageMarker as NSString).length

        let relocation = MarkdownAttachmentImageDecoration.insertionRelocation(
            in: text, cursorUTF16Offset: markerEnd
        )

        XCTAssertEqual(
            relocation,
            .init(newlineOffset: markerEnd, caretOffset: markerEnd + 1)
        )
    }

    func testTypingOnOrdinaryLinesIsNotRelocated() {
        let text = "위\n\(Self.imageMarker)\n아래"
        // Start of the document, the blank line's newline, and the line below.
        for cursor in [0, 1, (text as NSString).length] {
            XCTAssertNil(
                MarkdownAttachmentImageDecoration.insertionRelocation(
                    in: text, cursorUTF16Offset: cursor
                ),
                "cursor \(cursor) should type normally"
            )
        }
    }

    // A photo added from the picker, the camera or the keyboard bar goes where
    // the caret last was; a body that was never focused has no caret yet, and
    // the image goes after everything already written.
    func testImageInsertionWithoutACaretGoesToTheEndOfTheBody() {
        let text = "첫 문단\n둘째 문단"

        let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
            lastCaret: nil, in: text
        )

        XCTAssertEqual(selection, NSRange(location: (text as NSString).length, length: 0))
    }

    func testImageInsertionUsesTheLastCaretWhenThereIsOne() {
        let text = "첫 문단\n둘째 문단"

        let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
            lastCaret: NSRange(location: 3, length: 0), in: text
        )

        XCTAssertEqual(selection, NSRange(location: 3, length: 0))
    }

    func testImageInsertionClampsAStaleCaretToTheBody() {
        let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
            lastCaret: NSRange(location: 40, length: 5), in: "짧음"
        )

        XCTAssertEqual(selection, NSRange(location: 2, length: 0))
    }

    // Splitting a marker would turn the picture next to it into raw markdown,
    // and a selection would be replaced by the photo — neither is what adding
    // a photo from a sheet means.
    func testImageInsertionNeverLandsInsideAnotherImageMarker() {
        let text = "위\n\(Self.imageMarker)\n아래"
        let markerStart = ("위\n" as NSString).length
        let markerEnd = markerStart + (Self.imageMarker as NSString).length

        let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
            lastCaret: NSRange(location: markerStart + 5, length: 0), in: text
        )

        XCTAssertEqual(selection, NSRange(location: markerEnd, length: 0))
    }

    func testImageInsertionGoesAfterASelectionInsteadOfReplacingIt() {
        let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
            lastCaret: NSRange(location: 1, length: 2), in: "가나다라"
        )

        XCTAssertEqual(selection, NSRange(location: 3, length: 0))
    }

    // ▲/▼ swap the image line with the nearest line that has content. Blank
    // lines stay where they are, so the spacing between paragraphs survives.
    func testMovingAnImageUpSwapsWithThePreviousParagraphAndKeepsBlankLines() throws {
        let marker = Self.imageMarker
        let text = "문단1\n\n\(marker)\n\n문단2"
        let markerStart = ("문단1\n\n" as NSString).length

        let result = try XCTUnwrap(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: markerStart, direction: .up, in: text
            )
        )

        XCTAssertEqual(result.text, "\(marker)\n\n문단1\n\n문단2")
        XCTAssertEqual(result.cursorUTF16Offset, 0)
    }

    func testMovingAnImageDownSwapsWithTheNextParagraph() throws {
        let marker = Self.imageMarker
        let text = "문단1\n\(marker)\n문단2"
        let markerStart = ("문단1\n" as NSString).length

        let result = try XCTUnwrap(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: markerStart, direction: .down, in: text
            )
        )

        XCTAssertEqual(result.text, "문단1\n문단2\n\(marker)")
        XCTAssertEqual(result.cursorUTF16Offset, ("문단1\n문단2\n" as NSString).length)
    }

    func testMovingAnImageAcceptsAnyOffsetOnItsLine() throws {
        let marker = Self.imageMarker
        let text = "문단1\n\(marker)"
        let markerEnd = (text as NSString).length

        let result = try XCTUnwrap(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: markerEnd, direction: .up, in: text
            )
        )

        XCTAssertEqual(result.text, "\(marker)\n문단1")
    }

    func testMovingAnImagePastBlankOnlyLinesIsNotPossible() {
        let marker = Self.imageMarker
        let text = "\n  \n\(marker)\n\n"
        let markerStart = ("\n  \n" as NSString).length

        XCTAssertNil(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: markerStart, direction: .up, in: text
            )
        )
        XCTAssertNil(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: markerStart, direction: .down, in: text
            )
        )
    }

    func testMovingAnImageSwapsWithANeighbouringImage() throws {
        let first = "![](attachment:22222222-2222-2222-2222-222222222222 =300x200)"
        let second = Self.imageMarker
        let text = "\(first)\n\(second)"
        let secondStart = ("\(first)\n" as NSString).length

        let result = try XCTUnwrap(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: secondStart, direction: .up, in: text
            )
        )

        XCTAssertEqual(result.text, "\(second)\n\(first)")
        XCTAssertEqual(MarkdownAttachmentImageDecoration.matches(in: result.text).count, 2)
    }

    func testMovingIsOnlyForImageLines() {
        let text = "문단1\n문단2"

        XCTAssertNil(
            MarkdownCommandProcessor.movingAttachmentImage(
                at: ("문단1\n" as NSString).length, direction: .up, in: text
            )
        )
    }

    func testMoveButtonsSitInsideTheImageTopRightClearOfTheResizeHandle() {
        let image = CGRect(x: 0, y: 100, width: 300, height: 200)

        let buttons = MarkdownAttachmentImageDecoration.moveButtonRects(for: image)
        let handle = MarkdownAttachmentImageDecoration.handleRect(for: image)

        XCTAssertTrue(image.contains(buttons.up))
        XCTAssertTrue(image.contains(buttons.down))
        XCTAssertFalse(buttons.up.intersects(buttons.down))
        XCTAssertFalse(buttons.up.intersects(handle))
        XCTAssertFalse(buttons.down.intersects(handle))
        XCTAssertLessThan(buttons.up.minX, buttons.down.minX)
        XCTAssertEqual(buttons.down.maxX, image.maxX - 6, accuracy: 0.5)
        XCTAssertEqual(buttons.up.minY, image.minY + 6, accuracy: 0.5)
    }

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

/// Flips one checklist item the way both live editors do: one character, in place.
private func toggled(_ match: MarkdownChecklistDecoration.Match, in text: String) -> String {
    (text as NSString).replacingCharacters(in: match.stateRange, with: match.toggledState)
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
