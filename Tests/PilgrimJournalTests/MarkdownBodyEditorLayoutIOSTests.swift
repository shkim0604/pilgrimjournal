#if os(iOS)
import SwiftUI
import UIKit
import XCTest

@testable import PilgrimJournal

/// Hosts the real `MarkdownBodyEditor` inside a `ScrollView`, the way the
/// iPhone `EntryEditorView` does. The body text view used to report its
/// one-line height and sit in the vertical middle of the `minHeight` frame,
/// so in a new entry a tap on the blank body area above that middle hit
/// nothing and keys kept going to the title.
@MainActor
final class MarkdownBodyEditorLayoutIOSTests: XCTestCase {
    private let minHeight: CGFloat = 380
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    func testEmptyBodyFillsTheEditorAreaFromTheTop() throws {
        let (host, textView) = try hostEditor(text: "")

        let frame = contentFrame(of: textView, in: host)
        // The header row ("Markdown" menu) is about 30pt tall; the text view
        // must start right below it, not halfway down the editor area.
        XCTAssertLessThan(frame.minY, 60, "text view frame: \(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, minHeight - 1, "text view frame: \(frame)")
    }

    func testTapNearTheTopOfTheBlankBodyLandsOnTheTextView() throws {
        let (host, textView) = try hostEditor(text: "")

        // Well inside the editor area, above its vertical middle.
        let point = CGPoint(
            x: host.view.bounds.midX,
            y: host.view.safeAreaInsets.top + 120
        )
        let hit = host.view.hitTest(point, with: nil)
        XCTAssertNotNil(hit)
        XCTAssertTrue(
            hit?.isDescendant(of: textView) == true,
            "hit \(String(describing: hit)) instead of the body text view"
        )
    }

    func testExistingTextStartsDirectlyBelowTheHeaderRow() throws {
        let (host, textView) = try hostEditor(text: "첫 줄\n둘째 줄")

        let frame = contentFrame(of: textView, in: host)
        XCTAssertLessThan(frame.minY, 60, "text view frame: \(frame)")
    }

    private func hostEditor(
        text: String
    ) throws -> (UIHostingController<AnyView>, UITextView) {
        let root = AnyView(
            ScrollView {
                MarkdownBodyEditor(text: .constant(text), minHeight: minHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.view.layoutIfNeeded()

        let textView = try XCTUnwrap(
            firstTextView(in: host.view),
            "MarkdownBodyEditor did not create a UITextView"
        )
        return (host, textView)
    }

    /// The text view's frame measured from the top of the scroll content,
    /// i.e. from the top of `MarkdownBodyEditor` itself.
    private func contentFrame(
        of textView: UITextView,
        in host: UIHostingController<AnyView>
    ) -> CGRect {
        textView.convert(textView.bounds, to: host.view)
            .offsetBy(dx: 0, dy: -host.view.safeAreaInsets.top)
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}
#endif
