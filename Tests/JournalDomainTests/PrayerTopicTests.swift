#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class PrayerTopicTests: XCTestCase {
    func testNewPrayerNoteValidationLeavesWholeNoteStatusNil() throws {
        let validated = try EntryDetails().validated(for: .prayer)
        XCTAssertNil(validated.prayerStatus)
        XCTAssertNil(validated.answeredAt)
    }

    func testLegacyWholeNoteAnsweredStatusSurvivesValidation() throws {
        let answeredAt = Date(timeIntervalSince1970: 100)
        let details = EntryDetails(prayerStatus: .answered, answeredAt: answeredAt)
        let validated = try details.validated(for: .prayer)
        XCTAssertEqual(validated.prayerStatus, .answered)
        XCTAssertEqual(validated.answeredAt, answeredAt)
    }

    func testLegacyOngoingStatusClearsAnsweredAt() throws {
        let details = EntryDetails(prayerStatus: .ongoing, answeredAt: .now)
        let validated = try details.validated(for: .prayer)
        XCTAssertEqual(validated.prayerStatus, .ongoing)
        XCTAssertNil(validated.answeredAt)
    }

    func testTopicsAreSanitizedForPrayerKind() throws {
        let answeredAt = Date(timeIntervalSince1970: 50)
        let details = EntryDetails(prayerTopics: [
            PrayerTopic(
                text: "  아버지 건강 회복  ", status: .answered, memo: "  검사 정상  ",
                answeredAt: answeredAt),
            PrayerTopic(text: "   "),
            PrayerTopic(text: "수련회 준비", status: .ongoing, memo: "", answeredAt: .now),
        ])
        let validated = try details.validated(for: .prayer)
        let topics = try XCTUnwrap(validated.prayerTopics)
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].text, "아버지 건강 회복")
        XCTAssertEqual(topics[0].memo, "검사 정상")
        XCTAssertEqual(topics[0].answeredAt, answeredAt)
        XCTAssertEqual(topics[1].text, "수련회 준비")
        XCTAssertNil(topics[1].memo)
        XCTAssertNil(topics[1].answeredAt)
    }

    func testEmptyTopicArrayNormalizesToNil() throws {
        let details = EntryDetails(prayerTopics: [PrayerTopic(text: "  ")])
        XCTAssertNil(try details.validated(for: .prayer).prayerTopics)
    }

    func testTopicsAreStrippedForOtherKinds() throws {
        let details = EntryDetails(prayerTopics: [PrayerTopic(text: "제목")])
        XCTAssertNil(try details.validated(for: .diary).prayerTopics)
        XCTAssertNil(try details.validated(for: .bibleStudy).prayerTopics)
        XCTAssertNil(try details.validated(for: .reading).prayerTopics)
        XCTAssertNil(try details.validated(for: .memo).prayerTopics)
        XCTAssertNil(try details.validated(for: JournalKind(id: "custom-A")).prayerTopics)
    }

    func testAnswerDetailsAreSanitized() throws {
        let details = EntryDetails(prayerTopics: [
            PrayerTopic(
                text: "기다리는 제목", status: .answered, answeredAt: .now,
                answerOutcome: .wait, answerNote: "  더 기다리라 하심  "),
            PrayerTopic(
                text: "기도중인 제목", status: .ongoing,
                answerOutcome: .yes, answerNote: "지워져야 함"),
        ])
        let topics = try XCTUnwrap(try details.validated(for: .prayer).prayerTopics)
        XCTAssertEqual(topics[0].answerOutcome, .wait)
        XCTAssertEqual(topics[0].answerNote, "더 기다리라 하심")
        XCTAssertNil(topics[1].answerOutcome)
        XCTAssertNil(topics[1].answerNote)
    }

    func testCategoriesAreNormalizedAndCollectTopicCategories() throws {
        let details = EntryDetails(
            prayerTopics: [
                PrayerTopic(text: "가족 제목", category: " 성훈 "),
                PrayerTopic(text: "감사 제목", category: "감사"),
                PrayerTopic(text: "무소속 제목", category: "   "),
            ],
            prayerCategories: ["  감사 ", "", "감사", "중보"]
        )
        let validated = try details.validated(for: .prayer)
        XCTAssertEqual(validated.prayerCategories, ["감사", "중보", "성훈"])
        let topics = try XCTUnwrap(validated.prayerTopics)
        XCTAssertEqual(topics[0].category, "성훈")
        XCTAssertEqual(topics[1].category, "감사")
        XCTAssertNil(topics[2].category)
    }

    func testEmptyCategoryListNormalizesToNilButKeepsEmptySections() throws {
        let empty = EntryDetails(prayerCategories: [" ", ""])
        XCTAssertNil(try empty.validated(for: .prayer).prayerCategories)

        let sectionsOnly = EntryDetails(prayerCategories: ["감사", "정원"])
        XCTAssertEqual(
            try sectionsOnly.validated(for: .prayer).prayerCategories, ["감사", "정원"])
    }

    func testCategoriesAreStrippedForOtherKinds() throws {
        let details = EntryDetails(prayerCategories: ["감사"])
        XCTAssertNil(try details.validated(for: .diary).prayerCategories)
        XCTAssertNil(try details.validated(for: .bibleStudy).prayerCategories)
    }

    func testCarryOverLinesIncludeCategoryAndAnswerDetails() {
        let details = EntryDetails(prayerTopics: [
            PrayerTopic(
                text: "아버지 건강", status: .answered,
                answeredAt: Date(timeIntervalSince1970: 0),
                category: "감사", answerOutcome: .yes, answerNote: "검사 정상"),
            PrayerTopic(text: "이사", status: .answered, answerOutcome: .wait),
        ])
        XCTAssertEqual(
            details.carryOverLines(from: .prayer, timeZoneIdentifier: "Asia/Seoul"),
            """
            기도제목(감사): 아버지 건강 — 응답(Yes) (1970-01-01)
                응답 메모: 검사 정상
            기도제목: 이사 — 응답(Wait)
            """)
    }

    func testPrayerNoteWithOnlyTopicsCountsAsContent() throws {
        let draft = JournalEntryDraft(
            kind: .prayer,
            details: EntryDetails(prayerTopics: [PrayerTopic(text: "제목")]))
        XCTAssertNoThrow(try draft.validated(manual: true))

        let emptyTopics = JournalEntryDraft(
            kind: .prayer,
            details: EntryDetails(prayerTopics: [PrayerTopic(text: "   ")]))
        XCTAssertThrowsError(try emptyTopics.validated(manual: true)) { error in
            XCTAssertEqual(error as? JournalError, .emptyContent)
        }
    }

    func testLegacyDetailsBlobWithoutTopicsDecodes() throws {
        let data = Data(#"{"prayerStatus":"answered","answeredAt":100}"#.utf8)
        let details = try JSONDecoder().decode(EntryDetails.self, from: data)
        XCTAssertNil(details.prayerTopics)
        XCTAssertEqual(details.prayerStatus, .answered)
    }

    func testDetailsBlobWithUnknownKeysDecodes() throws {
        let data = Data(
            #"{"prayerTopics":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"제목","status":"ongoing","deadline":200}],"futureField":true}"#
                .utf8)
        let details = try JSONDecoder().decode(EntryDetails.self, from: data)
        XCTAssertEqual(details.prayerTopics?.first?.text, "제목")
    }

    func testCarryOverLinesIncludePrayerTopics() {
        let details = EntryDetails(prayerTopics: [
            PrayerTopic(text: "수련회 준비", status: .ongoing, memo: "11/14 강사 섭외"),
            PrayerTopic(
                text: "아버지 건강", status: .answered,
                answeredAt: Date(timeIntervalSince1970: 0)),
        ])
        XCTAssertEqual(
            details.carryOverLines(from: .prayer, timeZoneIdentifier: "Asia/Seoul"),
            """
            기도제목: 수련회 준비 — 기도 중
                메모: 11/14 강사 섭외
            기도제목: 아버지 건강 — 응답 (1970-01-01)
            """)
    }

    func testCarryOverLinesKeepLegacyStatusBeforeTopics() {
        let details = EntryDetails(
            prayerStatus: .ongoing,
            prayerTopics: [PrayerTopic(text: "제목")])
        XCTAssertEqual(
            details.carryOverLines(from: .prayer, timeZoneIdentifier: nil),
            "기도 상태: 기도 중\n기도제목: 제목 — 기도 중")
    }

    func testPrayerTopicRoundTripsThroughCodable() throws {
        let topic = PrayerTopic(
            text: "제목", status: .answered, memo: "메모",
            answeredAt: Date(timeIntervalSince1970: 1),
            createdAt: Date(timeIntervalSince1970: 2))
        let decoded = try JSONDecoder().decode(
            PrayerTopic.self, from: JSONEncoder().encode(topic))
        XCTAssertEqual(decoded, topic)
    }
}
#endif
