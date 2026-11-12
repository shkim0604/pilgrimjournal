import XCTest

@testable import JournalShareDrafts

final class PrayerRequestLinesTests: XCTestCase {
    func testPrayerRequestLinesParseListsAndNone() {
        let answer = "기도제목:\n- 이사가 잘 되도록 기도해 주세요\n• 새 이웃을 만나도록\n-\n덧붙임"
        XCTAssertEqual(
            PrayerRequestLines.parse(answer), ["이사가 잘 되도록 기도해 주세요", "새 이웃을 만나도록"])
        XCTAssertEqual(PrayerRequestLines.parse("없음"), [])
    }

    func testTidyDropsRepeatsAndKeepsThree() {
        let lines = [
            "아이가 좋은 친구를 만나도록 기도해 주세요 (아들/관계)",
            "아이가 좋은 친구를 만나도록 기도해 주세요. (나/가정)",
            "내일 사과 전화를 잘 드리도록 기도해 주세요 (나/관계)",
            "참을성 있는 엄마가 되도록 기도해 주세요 (나/가정)",
            "혼자 감당하지 않도록 기도해 주세요 (나/가정)",
        ]
        XCTAssertEqual(
            PrayerRequestLines.withoutRepeats(lines).map(PrayerRequestLines.sharedEnding),
            [
                "아이가 좋은 친구를 만나도록 (아들/관계)",
                "내일 사과 전화를 잘 드리도록 (나/관계)",
                "참을성 있는 엄마가 되도록 (나/가정)",
            ])
        XCTAssertEqual(PrayerRequestLines.withoutRepeats([]), [])
    }

    func testSharedEndingCutsOnlyThePrayForMeTail() {
        XCTAssertEqual(
            PrayerRequestLines.sharedEnding("어머니 검사 결과가 좋도록 기도해 주세요. (어머니/건강)"),
            "어머니 검사 결과가 좋도록 (어머니/건강)")
        XCTAssertEqual(
            PrayerRequestLines.sharedEnding("가게 매출 회복을 위해 기도해 주세요"), "가게 매출 회복을 위해")
        XCTAssertEqual(
            PrayerRequestLines.sharedEnding("남은 닷새 동안 체력이 버티게 해주세요 (나/건강)"),
            "남은 닷새 동안 체력이 버티게 해주세요 (나/건강)")
        XCTAssertEqual(PrayerRequestLines.sharedEnding("기도해 주세요"), "기도해 주세요")
    }

    func testLabelsMoveBetweenLanguagesByTable() {
        XCTAssertEqual(PrayerRequestLines.translatedLabel("나/가정", to: .english), "me/family")
        XCTAssertEqual(PrayerRequestLines.translatedLabel("mom/health", to: .korean), "엄마/건강")
        XCTAssertEqual(PrayerRequestLines.translatedLabel("지후/진로", to: .english), "지후/career")
        let split = PrayerRequestLines.splitLabel("Pray that the move goes well (me/family)")
        XCTAssertEqual(split.body, "Pray that the move goes well")
        XCTAssertEqual(split.label, "me/family")
        XCTAssertNil(PrayerRequestLines.splitLabel("꼬리표 없는 줄").label)
    }

    func testTranslatedLinesReadLikeTheOthers() {
        XCTAssertEqual(
            PrayerRequestLines.polishTranslation(
                "Please pray that the test results are good.", in: .english, cutEnding: true),
            "Pray that the test results are good")
        XCTAssertEqual(
            PrayerRequestLines.polishTranslation(
                "제가 죄책감 없이 쉴 수 있도록 기도해 주세요.", in: .korean, cutEnding: true),
            "죄책감 없이 쉴 수 있도록")
        XCTAssertEqual(
            PrayerRequestLines.withoutRepeats([
                "Pray that I pass (me/study)", "pray that I pass. (me/faith)",
            ]),
            ["Pray that I pass (me/study)"])
    }

    func testTranslationInputRestoresTheRequestTail() {
        func input(_ text: String, _ language: RequestLanguage = .korean) -> String {
            PrayerRequestLines.translationInput(text, from: language)
        }
        XCTAssertEqual(input("아버지가 회복하시도록"), "아버지가 회복하시도록 기도해 주세요")
        XCTAssertEqual(input("체력이 버티게 해주세요"), "체력이 버티게 해주세요")
        XCTAssertEqual(input(" 건강을 위해 기도해 주세요. "), "건강을 위해 기도해 주세요.")
        XCTAssertEqual(input(" Pray that I heal. ", .english), "Pray that I heal.")
    }

    func testGateSkipsOnlyOnAClearNo() {
        XCTAssertTrue(PrayerRequestLines.gateSaysNo("No"))
        XCTAssertFalse(PrayerRequestLines.gateSaysNo("Yes"))
        XCTAssertFalse(PrayerRequestLines.gateSaysNo("Nothing"))
        XCTAssertTrue(PrayerRequestLines.gateSaysNo("아니오"))
        XCTAssertTrue(PrayerRequestLines.gateSaysNo(" 아니요.\n"))
        XCTAssertFalse(PrayerRequestLines.gateSaysNo("예"))
        XCTAssertFalse(PrayerRequestLines.gateSaysNo(""))
        XCTAssertFalse(PrayerRequestLines.gateSaysNo(nil))
    }
}
