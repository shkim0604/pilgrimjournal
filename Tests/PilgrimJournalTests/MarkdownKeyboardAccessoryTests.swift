#if canImport(XCTest)
@testable import PilgrimJournal
import XCTest

final class MarkdownKeyboardAccessoryTests: XCTestCase {
    private func accessory(focusTitle: String) -> MarkdownKeyboardAccessory {
        MarkdownKeyboardAccessory(
            leading: [
                .init(title: "불릿", systemImage: "list.bullet") {},
                .init(title: focusTitle, systemImage: "arrow.up.left.and.arrow.down.right") {},
            ],
            trailing: [.init(title: "키보드 닫기", systemImage: nil) {}]
        )
    }

    func testSignatureIgnoresFreshClosures() {
        // EntryEditorView rebuilds the accessory, closures included, on every
        // render (twice per keystroke). Only what's on screen may count, or
        // the body's toolbar would be torn down while typing.
        XCTAssertEqual(
            accessory(focusTitle: "집중 모드").signature,
            accessory(focusTitle: "집중 모드").signature
        )
    }

    func testSignatureChangesWhenAButtonChanges() {
        XCTAssertNotEqual(
            accessory(focusTitle: "집중 모드").signature,
            accessory(focusTitle: "집중 모드 종료").signature
        )
    }

    func testSignatureKeepsLeadingAndTrailingApart() {
        let item = MarkdownKeyboardAccessory.Item(title: "a", systemImage: nil) {}
        XCTAssertNotEqual(
            MarkdownKeyboardAccessory(leading: [item], trailing: []).signature,
            MarkdownKeyboardAccessory(leading: [], trailing: [item]).signature
        )
    }

    func testActionsRunInDisplayOrder() {
        var calls: [String] = []
        let accessory = MarkdownKeyboardAccessory(
            leading: [.init(title: "a", systemImage: nil) { calls.append("a") }],
            trailing: [.init(title: "b", systemImage: nil) { calls.append("b") }]
        )
        accessory.items.forEach { $0.action() }
        XCTAssertEqual(calls, ["a", "b"])
    }
}
#endif
