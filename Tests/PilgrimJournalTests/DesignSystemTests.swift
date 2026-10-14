#if canImport(XCTest)
@testable import PilgrimJournal
import XCTest

final class DesignSystemTests: XCTestCase {
    func testEntrySummaryRemovesMarkdownMarkersAndKeepsReadableText() {
        let markdown = """
            # **아침 묵상**
            * 첫 번째 기도
            > 기억할 문장
            [관련 링크](https://example.com)
            """

        let summary = EntryListSummaryFormatter.summary(from: markdown)

        XCTAssertEqual(summary, "아침 묵상 첫 번째 기도 기억할 문장 관련 링크")
        XCTAssertFalse(summary.contains("#"))
        XCTAssertFalse(summary.contains("**"))

        let importedWithFormatMarker = "\u{FEFF}# 가져온 제목\n본문"
        XCTAssertEqual(
            EntryListSummaryFormatter.summary(from: importedWithFormatMarker),
            "가져온 제목 본문"
        )

        let dayOneMarkdown = """
            문장입니다\\.
            - [x] ~~완료~~
            ==중요==
            """
        XCTAssertEqual(
            EntryListSummaryFormatter.summary(from: dayOneMarkdown),
            "문장입니다. 완료 중요"
        )
    }

    func testEditorSaveStateProvidesStableAccessibleLabels() {
        XCTAssertEqual(EditorSaveState.saved.label, "저장됨")
        XCTAssertEqual(EditorSaveState.saving.label, "저장 중")
        XCTAssertEqual(EditorSaveState.failed("offline").label, "저장 오류")
    }

    func testEntryTitleRemovesMarkerAndFallsBackToFirstBodyLine() {
        XCTAssertEqual(
            EntryListSummaryFormatter.title(
                explicitTitle: "# 2024년 10월 28일",
                body: "본문",
                fallback: "일기"
            ),
            "2024년 10월 28일"
        )
        XCTAssertEqual(
            EntryListSummaryFormatter.title(
                explicitTitle: "",
                body: "\n## 아침 묵상\n내용",
                fallback: "기도노트"
            ),
            "아침 묵상"
        )
    }
}
#endif
