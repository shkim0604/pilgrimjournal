#if os(macOS)
import AppKit
import SwiftUI
import XCTest

@testable import PilgrimJournal

/// The Mac editor's ▲▼ buttons on the image under the caret — the same move
/// as on iPhone (`MarkdownCommandProcessor.movingAttachmentImage`), driven
/// through the real `MarkdownNSTextView` and its coordinator.
@MainActor
final class MacImageMoveTests: XCTestCase {
    private let marker = "![](attachment:\(UUID().uuidString) =200x100)"
    private var window: NSWindow?

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    func testUpButtonMovesTheImageAboveThePreviousParagraph() throws {
        let original = "문단1\n\n\(marker)"
        let (coordinator, textView, _) = makeEditor(text: original)
        textView.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        let buttons = try moveButtons(in: textView)

        XCTAssertEqual(coordinator.attachmentMoveTarget(at: center(of: buttons.up))?.direction, .up)
        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.down)))
        textView.needsDisplay = false
        XCTAssertTrue(coordinator.moveAttachmentImage(at: center(of: buttons.up)))

        XCTAssertEqual(textView.string, "\(marker)\n\n문단1")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        // Unlike UIKit, NSTextView paints the text and these decorations in
        // one view and invalidates itself when the string changes, so the
        // swapped pictures are redrawn without the explicit request iOS needs.
        XCTAssertTrue(textView.needsDisplay)
    }

    func testMoveButtonsOnlyAnswerForTheImageUnderTheCaret() throws {
        let (coordinator, textView, _) = makeEditor(text: "문단1\n\(marker)\n문단2")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let buttons = try moveButtons(in: textView)

        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.up)))
        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.down)))
        XCTAssertFalse(coordinator.moveAttachmentImage(at: center(of: buttons.up)))
        XCTAssertEqual(textView.string, "문단1\n\(marker)\n문단2")
    }

    // MARK: - Hosting

    private func makeEditor(
        text: String
    ) -> (LiveMarkdownTextEditor.Coordinator, MarkdownNSTextView, NSView) {
        let editor = LiveMarkdownTextEditor(
            text: .constant(text),
            selection: .constant(NSRange(location: 0, length: 0)),
            autoFocus: false,
            textScale: 1
        )
        let coordinator = LiveMarkdownTextEditor.Coordinator(parent: editor)
        let (scrollView, textView) = LiveMarkdownTextEditor.makeEditorViews(textScale: 1)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        scrollView.frame = host.bounds
        host.addSubview(scrollView)
        // `needsDisplay` only sticks for a view that is in a window.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.string = text
        if let storage = textView.textStorage {
            LiveMarkdownStyler.apply(
                to: storage,
                containerWidth: textView.textContainer?.size.width ?? 600
            )
        }
        host.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return (coordinator, textView, host)
    }

    private func moveButtons(in textView: NSTextView) throws -> (up: CGRect, down: CGRect) {
        let match = try XCTUnwrap(
            MarkdownAttachmentImageDecoration.matches(in: textView.string).first)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: match.markerRange, actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil
        )
        let imageRect = MarkdownAttachmentImageDecoration.imageRect(
            origin: textView.textContainerOrigin,
            fragment: fragment,
            displaySize: LiveMarkdownStyler.attachmentImageDisplaySize(
                storedWidth: match.storedWidth,
                storedHeight: match.storedHeight,
                containerWidth: textContainer.size.width
            )
        )
        return MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
#endif
