#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension MarkdownSupportTests {
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
}

#endif
