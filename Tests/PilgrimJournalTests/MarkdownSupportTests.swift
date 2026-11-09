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
    func testOpeningTextEchoAfterFirstEditStillAllowsALaterRevisionRestore() {
        let editor = LiveMarkdownTextEditor(
            text: .constant("원문"),
            selection: .constant(NSRange(location: 0, length: 0)),
            autoFocus: false,
            textScale: 1
        )
        let coordinator = editor.makeCoordinator()
        coordinator.publish("원문 수정")

        XCTAssertTrue(coordinator.isOpeningTextEcho("원문", current: "원문 수정"))
        XCTAssertFalse(coordinator.isOpeningTextEcho("원문 수정", current: "원문 수정"))
        XCTAssertFalse(coordinator.isOpeningTextEcho("원문", current: "원문 수정"))
    }

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

}

#endif
