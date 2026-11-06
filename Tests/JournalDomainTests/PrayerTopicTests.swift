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
