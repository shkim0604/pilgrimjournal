#if canImport(XCTest)
import XCTest

@testable import ShareCardEval

final class DatePhraseResolverTests: XCTestCase {
    private let thursday = DayDate(2026, 10, 15)

    /// The eval's expected deadlines are hand-computed; this keeps them honest.
    func testEveryFixtureDeadlinePhraseResolvesToItsLabel() {
        for entry in EvalFixtures.all {
            for deadline in entry.expected.deadlines {
                XCTAssertTrue(
                    entry.body.contains(deadline.phrase), "\(entry.id): \(deadline.phrase)")
                XCTAssertEqual(
                    DatePhraseResolver.resolve(deadline.phrase, from: entry.date), deadline.date,
                    "\(entry.id): \(deadline.phrase)")
            }
        }
    }

    func testFixturesHaveUniqueIDsAndLongEntries() {
        let ids = EvalFixtures.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThanOrEqual(EvalFixtures.all.filter { $0.body.count >= 2_000 }.count, 2)
    }

    func testWeeksStartOnMonday() {
        XCTAssertEqual(EvalCalendar.weekdayIndex(thursday), 3)
        XCTAssertEqual(EvalCalendar.monday(ofWeekContaining: thursday), DayDate(2026, 10, 12))
        XCTAssertEqual(
            DatePhraseResolver.resolve("이번 주 일요일", from: thursday), DayDate(2026, 10, 18))
        XCTAssertEqual(
            DatePhraseResolver.resolve("다다음 주 월요일", from: thursday), DayDate(2026, 10, 26))
        XCTAssertEqual(
            DatePhraseResolver.resolve("다음 금요일", from: thursday), DayDate(2026, 10, 23))
        XCTAssertEqual(DatePhraseResolver.resolve("금요일에", from: thursday), DayDate(2026, 10, 16))
    }

    func testExplicitDateWinsOverRelativePhrase() {
        XCTAssertEqual(
            DatePhraseResolver.resolve("다음 주 화요일(10월 21일)", from: thursday),
            DayDate(2026, 10, 21))
    }

    func testPastMonthDayRollsToNextYear() {
        XCTAssertEqual(DatePhraseResolver.resolve("1월 5일", from: thursday), DayDate(2027, 1, 5))
        XCTAssertEqual(
            DatePhraseResolver.resolve("다음 달(11월) 21일", from: thursday), DayDate(2026, 11, 21))
    }

    func testUnknownPhrasesAreLeftToTheModel() {
        XCTAssertNil(DatePhraseResolver.resolve("곧", from: thursday))
        XCTAssertNil(DatePhraseResolver.resolve("this month", from: thursday))
        XCTAssertNil(DatePhraseResolver.resolve("다음 달 30일", from: DayDate(2027, 1, 10)))
    }

    func testCalendarHintsSpellOutRelativeDates() {
        let hints = CalendarHints.text(for: DayDate(2026, 12, 20))
        XCTAssertTrue(hints.contains("작성일: 2026-12-20 (일)"))
        XCTAssertTrue(hints.contains("다음 달: 2027년 1월, 다음 달 말 = 2027-01-31"))
        XCTAssertTrue(hints.contains("다음 주: 월 2026-12-21"))
    }

    func testYesNoParsing() {
        XCTAssertEqual(EvalScorer.parseYesNo("예"), true)
        XCTAssertEqual(EvalScorer.parseYesNo("답: 아니오."), false)
        XCTAssertEqual(EvalScorer.parseYesNo(" Yes"), true)
        XCTAssertNil(EvalScorer.parseYesNo("잘 모르겠습니다"))
    }

    func testPrayerRequestLinesParseListsAndNone() {
        let answer = "기도제목:\n- 이사가 잘 되도록 기도해 주세요\n• 새 이웃을 만나도록\n-\n덧붙임"
        XCTAssertEqual(
            SharePrompts.requestLines(answer), ["이사가 잘 되도록 기도해 주세요", "새 이웃을 만나도록"])
        XCTAssertEqual(SharePrompts.requestLines("없음"), [])
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
            SharePrompts.tidyRequestLines(lines),
            [
                "아이가 좋은 친구를 만나도록 (아들/관계)",
                "내일 사과 전화를 잘 드리도록 (나/관계)",
                "참을성 있는 엄마가 되도록 (나/가정)",
            ])
        XCTAssertEqual(SharePrompts.tidyRequestLines([]), [])
    }

    func testSharedEndingCutsOnlyThePrayForMeTail() {
        XCTAssertEqual(
            SharePrompts.sharedEnding("어머니 검사 결과가 좋도록 기도해 주세요. (어머니/건강)"),
            "어머니 검사 결과가 좋도록 (어머니/건강)")
        XCTAssertEqual(SharePrompts.sharedEnding("가게 매출 회복을 위해 기도해 주세요"), "가게 매출 회복을 위해")
        XCTAssertEqual(
            SharePrompts.sharedEnding("남은 닷새 동안 체력이 버티게 해주세요 (나/건강)"),
            "남은 닷새 동안 체력이 버티게 해주세요 (나/건강)")
        XCTAssertEqual(SharePrompts.sharedEnding("기도해 주세요"), "기도해 주세요")
    }

    func testDiaryLanguageFollowsTheScriptItIsMostlyWrittenIn() {
        XCTAssertEqual(RequestLanguage.detect("엄마 검사 결과가 다음 주 목요일에 나온다."), .korean)
        XCTAssertEqual(RequestLanguage.detect("Mom's surgery is next Tuesday."), .english)
        XCTAssertEqual(
            RequestLanguage.detect("Global launch가 다음 주 화요일로 확정됐다. QA를 다 맡고 있다."), .korean)
        for diary in PrayerDiaryFixtures.all {
            let expected: RequestLanguage = diary.id.hasPrefix("en-") ? .english : .korean
            XCTAssertEqual(
                RequestLanguage.detect(diary.title + "\n" + diary.body), expected, diary.id)
        }
    }

    func testLabelsMoveBetweenLanguagesByTable() {
        XCTAssertEqual(SharePrompts.translatedLabel("나/가정", to: .english), "me/family")
        XCTAssertEqual(SharePrompts.translatedLabel("mom/health", to: .korean), "엄마/건강")
        XCTAssertEqual(SharePrompts.translatedLabel("지후/진로", to: .english), "지후/career")
        let split = SharePrompts.splitLabel("Pray that the move goes well (me/family)")
        XCTAssertEqual(split.body, "Pray that the move goes well")
        XCTAssertEqual(split.label, "me/family")
        XCTAssertNil(SharePrompts.splitLabel("꼬리표 없는 줄").label)
    }

    func testTranslatedLinesReadLikeTheOthers() {
        XCTAssertEqual(
            SharePrompts.polishTranslation(
                "Please pray that the test results are good.", in: .english, cutEnding: true),
            "Pray that the test results are good")
        XCTAssertEqual(
            SharePrompts.polishTranslation(
                "제가 죄책감 없이 쉴 수 있도록 기도해 주세요.", in: .korean, cutEnding: true),
            "죄책감 없이 쉴 수 있도록")
        XCTAssertEqual(
            SharePrompts.withoutRepeats([
                "Pray that I pass (me/study)", "pray that I pass. (me/faith)",
            ]),
            ["Pray that I pass (me/study)"])
    }

    func testGateSkipsOnlyOnAClearNo() {
        XCTAssertTrue(SharePrompts.gateSaysNo("No"))
        XCTAssertFalse(SharePrompts.gateSaysNo("Yes"))
        XCTAssertFalse(SharePrompts.gateSaysNo("Nothing"))
        XCTAssertTrue(SharePrompts.gateSaysNo("아니오"))
        XCTAssertTrue(SharePrompts.gateSaysNo(" 아니요.\n"))
        XCTAssertFalse(SharePrompts.gateSaysNo("예"))
        XCTAssertFalse(SharePrompts.gateSaysNo(""))
        XCTAssertFalse(SharePrompts.gateSaysNo(nil))
    }

    func testPrayerDiariesArePageLongWithUniqueIDs() {
        let ids = PrayerDiaryFixtures.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for diary in PrayerDiaryFixtures.all {
            XCTAssertGreaterThanOrEqual(diary.body.count, 500, diary.id)
            for name in diary.names { XCTAssertTrue(diary.body.contains(name), diary.id) }
        }
    }

    func testPromptTemplateFillsDiaryFields() {
        let entry = PrayerDiaryFixtures.all[0].entry
        let prompt = SharePrompts.fill("{날짜}|{제목}|{본문}", with: entry)
        XCTAssertEqual(prompt, "\(entry.date)|\(entry.title)|\(entry.body)")
        XCTAssertEqual(
            SharePrompts.prayerRequests(entry),
            SharePrompts.fill(SharePrompts.prayerRequestTemplate, with: entry))
    }

    func testHTTPRequestWaitsForTheWholeBody() {
        let head = "POST /api/run HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\n"
        XCTAssertNil(HTTPRequest(parsing: Data((head + "ab").utf8)))
        let request = HTTPRequest(parsing: Data((head + "abcd").utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/api/run")
        XCTAssertEqual(request.map { String(decoding: $0.body, as: UTF8.self) }, "abcd")
    }

    func testHTTPRequestRejectsOtherOrigins() {
        let request = { (origin: String) in
            HTTPRequest(parsing: Data("GET / HTTP/1.1\r\nOrigin: \(origin)\r\n\r\n".utf8))!
        }
        XCTAssertTrue(request("http://localhost:8765").isSameOrigin(port: 8765))
        XCTAssertFalse(request("https://example.com").isSameOrigin(port: 8765))
        XCTAssertTrue(
            HTTPRequest(parsing: Data("GET / HTTP/1.1\r\n\r\n".utf8))!.isSameOrigin(port: 1))
    }

    func testNameLeaksMatchWholeASCIIWordsOnly() {
        let prose = ["card": "동료 J가 잘 쉬도록. Jesus께 맡깁니다. 민지를 위해"]
        XCTAssertEqual(EvalScorer.nameLeaks(["J", "민지"], in: prose), ["J", "민지"])
        XCTAssertEqual(EvalScorer.nameLeaks(["J"], in: ["card": "Jesus"]), [])
    }
}
#endif
