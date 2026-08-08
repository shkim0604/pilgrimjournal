#if canImport(XCTest)
import Foundation
@testable import PilgrimJournal
import XCTest

final class MarkdownSupportTests: XCTestCase {
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
}
#endif
