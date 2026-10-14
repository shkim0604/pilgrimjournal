#if os(iOS)
import CloudKit
import DayOneImport
import Foundation
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI
import UIKit
import XCTest

@testable import PilgrimJournal

/// Drives the real iPhone entry editor inside a window. `insertText` is what
/// the software keyboard calls, so these tests run the same delegate and
/// SwiftUI update path as typing on a device, without the Simulator's
/// hardware-keyboard injection. Run with `xcodebuild test` on an iOS
/// Simulator destination; `swift test` on macOS skips this file.
@MainActor
final class LiveMarkdownTextEditorIOSTests: XCTestCase {
    private var window: UIWindow?
    private var root: URL?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    /// SwiftUI's first update after a keystroke can still carry the body from
    /// before it. Every later keystroke's stale value is one the editor
    /// published itself, so it is recognised as an echo — but the text the
    /// editor opened with had never been published, so its echo was taken for
    /// an external change and wiped out the first character typed.
    func testFirstKeystrokeAfterOpeningIsKept() throws {
        let textView = try openEditor()
        let initial = textView.text ?? ""

        type("a", into: textView)

        XCTAssertEqual(textView.text, initial + "a")
        XCTAssertEqual(
            textView.selectedRange,
            NSRange(location: (initial + "a").utf16.count, length: 0)
        )
    }

    func testTypingInBurstsWithPausesKeepsEveryCharacterInOrder() throws {
        let textView = try openEditor()
        let initial = textView.text ?? ""

        for chunk in ["abc", "def", "ghi"] {
            for character in chunk {
                textView.insertText(String(character))
            }
            pumpRunLoop(seconds: 1.0)
        }

        XCTAssertEqual(textView.text, initial + "abcdefghi")
    }

    // MARK: - Hosting

    private func openEditor() throws -> UITextView {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-editor-\(UUID().uuidString)",
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

        let textView = try XCTUnwrap(
            findTextView(in: window),
            "editor text view not found"
        )
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        pumpRunLoop()
        return textView
    }

    private func type(_ text: String, into textView: UITextView) {
        textView.insertText(text)
        pumpRunLoop(seconds: 1.0)
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
}
#endif
