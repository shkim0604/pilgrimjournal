#if os(iOS)
import Foundation
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI
import UIKit
import XCTest

@testable import PilgrimJournal

/// Drives the real iPhone body editor inside a window: photos added from
/// outside the text view (picker, camera, keyboard bar) and the ▲/▼ move
/// buttons. Both rewrite the body programmatically, so these check that the
/// edit lands where it should *and* that typing afterwards is kept — the
/// editor's echo detection must recognise the new text as its own. Run with
/// `xcodebuild test` on an iOS Simulator destination; `swift test` on macOS
/// skips this file.
@MainActor
final class BodyImagePlacementIOSTests: XCTestCase {
    private var window: UIWindow?
    private let inserter = MarkdownImageInserter()
    private var requestedSources: [AttachmentPhotoSource] = []

    private var root: URL?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    /// The real iPhone entry editor, not the bare body editor: SwiftUI's first
    /// update after the body changes can still carry the body from before,
    /// and only this screen's update timing shows it. A photo inserted before
    /// anything was typed must survive that late echo.
    func testPhotoStaysInTheBodyOfTheRealEntryEditor() throws {
        let textView = try openEntryEditor()
        let coordinator = try XCTUnwrap(textView.delegate as? LiveMarkdownTextEditor.Coordinator)
        let inserter = try XCTUnwrap(coordinator.parent.imageInserter)
        let id = UUID()

        XCTAssertTrue(inserter.insertImage(id: id, data: Self.photo))
        pumpRunLoop(seconds: 1.0)

        XCTAssertEqual(
            MarkdownAttachmentImageDecoration.matches(in: textView.text).map(\.attachmentID),
            [id],
            textView.text
        )
    }

    func testPhotoWithoutACaretGoesToTheEndOfTheBody() throws {
        let (box, textView) = try openEditor(body: "첫 문단")
        let id = UUID()

        XCTAssertTrue(inserter.insertImage(id: id, data: Self.photo))
        pumpRunLoop()

        XCTAssertTrue(
            box.text.hasPrefix("첫 문단\n![](attachment:\(id.uuidString) ="),
            box.text
        )
        XCTAssertEqual(
            MarkdownAttachmentImageDecoration.matches(in: box.text).map(\.attachmentID),
            [id]
        )
        XCTAssertEqual(textView.text, box.text)
    }

    func testPhotoGoesWhereTheCaretWasBeforeThePickerOpened() throws {
        let (box, textView) = try openEditor(body: "앞뒤")
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 1, length: 0)
        pumpRunLoop()
        // Presenting the photo picker takes the keyboard away.
        textView.resignFirstResponder()
        pumpRunLoop()
        let id = UUID()

        XCTAssertTrue(inserter.insertImage(id: id, data: Self.photo))
        pumpRunLoop()

        let lines = box.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, box.text)
        XCTAssertEqual(lines.first, "앞")
        XCTAssertEqual(lines.last, "뒤")
        XCTAssertEqual(MarkdownAttachmentImageDecoration.matches(in: box.text).count, 1)
    }

    func testPhotosAddedTogetherKeepTheirOrder() throws {
        let (box, _) = try openEditor(body: "본문")
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(inserter.insertImage(id: first, data: Self.photo))
        XCTAssertTrue(inserter.insertImage(id: second, data: Self.photo))
        pumpRunLoop()

        XCTAssertEqual(
            MarkdownAttachmentImageDecoration.matches(in: box.text).map(\.attachmentID),
            [first, second]
        )
    }

    func testTypingAfterAnInsertedPhotoKeepsEveryCharacter() throws {
        let (box, textView) = try openEditor(body: "본문")
        XCTAssertTrue(inserter.insertImage(id: UUID(), data: Self.photo))
        pumpRunLoop()
        let afterInsertion = box.text
        XCTAssertTrue(textView.becomeFirstResponder())
        pumpRunLoop()

        for character in "abc" {
            textView.insertText(String(character))
            pumpRunLoop(seconds: 0.5)
        }

        XCTAssertEqual(textView.text, afterInsertion + "\nabc")
        XCTAssertEqual(box.text, textView.text)
    }

    func testUpButtonMovesTheImageAboveThePreviousParagraphAndUndoes() throws {
        let marker = "![](attachment:\(UUID().uuidString) =200x100)"
        let original = "문단1\n\n\(marker)"
        let (box, textView) = try openEditor(body: original)
        let coordinator = try XCTUnwrap(textView.delegate as? LiveMarkdownTextEditor.Coordinator)
        textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
        pumpRunLoop()
        let buttons = try moveButtons(in: textView)

        XCTAssertEqual(coordinator.attachmentMoveTarget(at: center(of: buttons.up))?.direction, .up)
        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.down)))
        XCTAssertTrue(coordinator.moveAttachmentImage(at: center(of: buttons.up)))
        pumpRunLoop()

        XCTAssertEqual(box.text, "\(marker)\n\n문단1")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))

        textView.undoManager?.undo()
        pumpRunLoop()
        XCTAssertEqual(box.text, original)
    }

    /// The body is a UIKit text view, so SwiftUI's keyboard toolbar never
    /// shows above it — only its own `inputAccessoryView` does. 📷 has to be
    /// there; six items is the most that fits, so 키보드 닫기 made room.
    func testBodyKeyboardBarOffersPhotoInsteadOfDismiss() throws {
        let textView = try openEntryEditor()

        let titles =
            try XCTUnwrap(textView.inputAccessoryView as? UIToolbar).items?
            .compactMap(\.accessibilityLabel) ?? []

        XCTAssertTrue(titles.contains("사진"), "\(titles)")
        XCTAssertFalse(titles.contains("키보드 닫기"), "\(titles)")
        XCTAssertLessThanOrEqual(titles.count, 6)
    }

    /// Images are drawn by the text view's own `draw(_:)`, which UIKit does
    /// not rerun just because the characters changed. A move that only
    /// swaps two image lines changed no glyphs anyone can see, so without an
    /// explicit redraw the old pictures stayed where they were.
    func testMovingAnImageRedrawsThePictures() throws {
        let marker = "![](attachment:\(UUID().uuidString) =200x100)"
        let original = "문단1\n\(marker)"
        let (_, textView) = try openEditor(body: original)
        let coordinator = try XCTUnwrap(textView.delegate as? LiveMarkdownTextEditor.Coordinator)
        textView.selectedRange = NSRange(location: (original as NSString).length, length: 0)
        pumpRunLoop()
        let buttons = try moveButtons(in: textView)
        XCTAssertFalse(textView.layer.needsDisplay())

        XCTAssertTrue(coordinator.moveAttachmentImage(at: center(of: buttons.up)))

        XCTAssertTrue(textView.layer.needsDisplay())
    }

    func testMoveButtonsOnlyAnswerForTheImageUnderTheCaret() throws {
        let marker = "![](attachment:\(UUID().uuidString) =200x100)"
        let (_, textView) = try openEditor(body: "문단1\n\(marker)\n문단2")
        let coordinator = try XCTUnwrap(textView.delegate as? LiveMarkdownTextEditor.Coordinator)
        textView.selectedRange = NSRange(location: 0, length: 0)
        pumpRunLoop()
        let buttons = try moveButtons(in: textView)

        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.up)))
        XCTAssertNil(coordinator.attachmentMoveTarget(at: center(of: buttons.down)))
    }

    func testEditMenuOffersPhotoInsertionAtTheCaret() throws {
        let (_, textView) = try openEditor(body: "본문")
        let coordinator = try XCTUnwrap(textView.delegate as? LiveMarkdownTextEditor.Coordinator)

        let atCaret = coordinator.textView(
            textView,
            editMenuForTextIn: NSRange(location: 1, length: 0),
            suggestedActions: [UIAction(title: "붙여넣기") { _ in }]
        )
        let overSelection = coordinator.textView(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 1),
            suggestedActions: []
        )

        XCTAssertEqual(atCaret?.children.first?.title, "사진 삽입")
        XCTAssertEqual(atCaret?.children.last?.title, "붙여넣기")
        XCTAssertNil(overSelection)
    }

    // MARK: - Hosting

    private func openEditor(body: String) throws -> (BodyBox, UITextView) {
        let box = BodyBox(text: body)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(
            rootView: HostedBody(
                box: box,
                inserter: inserter,
                requestImageInsertion: { [weak self] in self?.requestedSources.append($0) }
            )
        )
        window.makeKeyAndVisible()
        self.window = window
        pumpRunLoop()
        let textView = try XCTUnwrap(findTextView(in: window), "editor text view not found")
        return (box, textView)
    }

    private func openEntryEditor() throws -> UITextView {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-body-image-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        self.root = root
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "editor.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(
            rootView: EntryEditorView(entry: nil).environmentObject(model)
        )
        window.makeKeyAndVisible()
        self.window = window
        pumpRunLoop()
        return try XCTUnwrap(findTextView(in: window), "editor text view not found")
    }

    private func moveButtons(in textView: UITextView) throws -> (up: CGRect, down: CGRect) {
        let match = try XCTUnwrap(
            MarkdownAttachmentImageDecoration.matches(in: textView.text).first)
        let layoutManager = textView.layoutManager
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: match.markerRange, actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil
        )
        let imageRect = MarkdownAttachmentImageDecoration.imageRect(
            origin: CGPoint(
                x: textView.textContainerInset.left, y: textView.textContainerInset.top
            ),
            fragment: fragment,
            displaySize: LiveMarkdownStyler.attachmentImageDisplaySize(
                storedWidth: match.storedWidth,
                storedHeight: match.storedHeight,
                containerWidth: textView.textContainer.size.width
            )
        )
        return MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView,
            textView.delegate is LiveMarkdownTextEditor.Coordinator
        {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    private func pumpRunLoop(seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static let photo: Data = UIGraphicsImageRenderer(
        size: CGSize(width: 300, height: 200)
    ).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    }
}

@MainActor
private final class BodyBox: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}

private struct HostedBody: View {
    @ObservedObject var box: BodyBox
    let inserter: MarkdownImageInserter
    let requestImageInsertion: (AttachmentPhotoSource) -> Void

    var body: some View {
        ScrollView {
            MarkdownBodyEditor(
                text: $box.text,
                imageInserter: inserter,
                requestImageInsertion: requestImageInsertion
            )
        }
    }
}
#endif
