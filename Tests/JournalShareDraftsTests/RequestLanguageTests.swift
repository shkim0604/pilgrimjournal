import XCTest

@testable import JournalShareDrafts

final class RequestLanguageTests: XCTestCase {
    func testDiaryLanguageFollowsTheScriptItIsMostlyWrittenIn() {
        XCTAssertEqual(RequestLanguage.detect("엄마 검사 결과가 다음 주 목요일에 나온다."), .korean)
        XCTAssertEqual(RequestLanguage.detect("Mom's surgery is next Tuesday."), .english)
        XCTAssertEqual(
            RequestLanguage.detect("Global launch가 다음 주 화요일로 확정됐다. QA를 다 맡고 있다."), .korean)
    }
}
