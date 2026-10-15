#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class JournalDomainTests: XCTestCase {
    func testInvalidManualKindMessageIsFixedSentence() {
        XCTAssertEqual(
            JournalError.invalidManualKind.errorDescription,
            "미분류로는 새 기록을 만들 수 없습니다. 다른 유형을 골라 주세요.")
    }

    func testJournalKindEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([JournalKind.prayer, JournalKind(id: "custom-A")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["prayer","custom-A"]"#)
    }

    func testUnknownKindIdSurvivesDecoding() throws {
        let draft = try JSONDecoder().decode(
            JournalEntryDraft.self,
            from: Data(
                #"{"kind":"custom-X","title":"t","body":"b","occurredAt":0,"tags":[],"isStarred":false,"isPinned":false,"details":{}}"#
                    .utf8))
        XCTAssertEqual(draft.kind.id, "custom-X")
        XCTAssertNil(draft.kind.builtIn)
    }

    func testCustomKindIsManualAndClearsAllDetails() throws {
        let draft = JournalEntryDraft(
            kind: JournalKind(id: "custom-A"), body: "본문",
            details: EntryDetails(prayerStatus: .answered, mood: "평안"))
        XCTAssertEqual(try draft.validated(manual: true).details, EntryDetails())
    }

    func testManualEntryRequiresConcreteKind() throws {
        let draft = JournalEntryDraft(kind: .unclassified, body: "본문")
        XCTAssertThrowsError(try draft.validated(manual: true)) { error in
            XCTAssertEqual(error as? JournalError, .invalidManualKind)
        }
    }

    func testMemoCanBeCreatedManuallyAndHasNoTypeSpecificDetails() throws {
        XCTAssertFalse(JournalKind.memo.isUnclassified)
        XCTAssertEqual(BuiltInKind.memo.defaultName, "메모")

        let details = EntryDetails(
            prayerStatus: .answered,
            answeredAt: .now,
            scriptureReference: "요한복음 1:1",
            bookTitle: "책",
            bookAuthor: "저자",
            mood: "평온"
        )

        XCTAssertEqual(try details.validated(for: .memo), EntryDetails())
    }

    func testDetailsAreSanitizedForKind() throws {
        let details = EntryDetails(
            prayerStatus: .answered,
            answeredAt: Date(timeIntervalSince1970: 1),
            scriptureReference: "요 3:16",
            bookTitle: "책",
            mood: "평안"
        )
        let validated = try details.validated(for: .prayer)
        XCTAssertEqual(validated.prayerStatus, .answered)
        XCTAssertNil(validated.scriptureReference)
        XCTAssertNil(validated.bookTitle)
        XCTAssertNil(validated.mood)
    }

    func testStableDayOneIdentifierIsDeterministic() {
        let first = StableIdentifier.fromDayOne(sourceUUID: "not-a-uuid")
        let second = StableIdentifier.fromDayOne(sourceUUID: "not-a-uuid")
        XCTAssertEqual(first, second)
    }

    func testNotebookAssignmentIsSeparateFromVisibleTags() {
        var draft = JournalEntryDraft(
            kind: .diary,
            body: "본문",
            tags: ["개인", "기도"]
        )

        draft.notebookName = "  여름 묵상  "

        XCTAssertEqual(draft.notebookName, "여름 묵상")
        XCTAssertEqual(draft.visibleTags, ["개인", "기도"])

        draft.notebookName = "독서 모임"
        XCTAssertEqual(draft.notebookName, "독서 모임")
        XCTAssertEqual(draft.visibleTags, ["개인", "기도"])
        XCTAssertEqual(
            draft.tags.compactMap { tag in
                NotebookTagCodec.notebookName(in: [tag])
            },
            ["독서 모임"]
        )
    }

    func testClassificationUsesHighestPriorityAndDetectsConflict() {
        let engine = ClassificationEngine()
        let tagRule = ClassificationRuleRecord(
            source: .tag,
            value: "book",
            targetKind: .reading,
            priority: 5
        )
        let templateRule = ClassificationRuleRecord(
            source: .templateTitle,
            value: "기도",
            targetKind: .prayer,
            priority: 10
        )
        let decision = engine.classify(
            ClassificationCandidate(
                tags: ["Book"],
                templateUUID: nil,
                templateTitle: "기도"
            ),
            rules: [tagRule, templateRule]
        )
        XCTAssertEqual(decision.kind, .prayer)
        XCTAssertEqual(decision.ruleID, templateRule.id)

        var conflicting = tagRule
        conflicting.targetKind = .diary
        let conflict = engine.classify(
            ClassificationCandidate(
                tags: ["book"],
                templateUUID: nil,
                templateTitle: nil
            ),
            rules: [tagRule, conflicting]
        )
        XCTAssertEqual(conflict.kind, .unclassified)
        XCTAssertTrue(conflict.isConflict)
    }

    func testRevisionResolverIsDeterministic() {
        let date = Date(timeIntervalSince1970: 100)
        let draft = JournalEntryDraft(kind: .diary, body: "내용")
        let lhs = EntryRevisionRecord(
            entryID: UUID(),
            parentRevisionID: nil,
            snapshot: draft,
            createdAt: date,
            deviceID: "A"
        )
        let rhs = EntryRevisionRecord(
            entryID: lhs.entryID,
            parentRevisionID: nil,
            snapshot: draft,
            createdAt: date,
            deviceID: "B"
        )
        XCTAssertEqual(RevisionResolver().winner(lhs, rhs).deviceID, "B")
        XCTAssertEqual(RevisionResolver().winner(rhs, lhs).deviceID, "B")
    }

    func testClassificationRuleResolverConvergesRegardlessOfDeliveryOrder() {
        let identifier = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let date = Date(timeIntervalSince1970: 100)
        let macEdit = ClassificationRuleRecord(
            id: identifier,
            source: .tag,
            value: "묵상",
            targetKind: .bibleStudy,
            priority: 10,
            updatedAt: date
        )
        let phoneEdit = ClassificationRuleRecord(
            id: identifier,
            source: .tag,
            value: "묵상",
            targetKind: .diary,
            priority: 10,
            updatedAt: date
        )
        let resolver = ClassificationRuleResolver()

        XCTAssertEqual(
            resolver.winner(macEdit, phoneEdit),
            resolver.winner(phoneEdit, macEdit)
        )
        XCTAssertEqual(
            resolver.winner(macEdit, phoneEdit).targetKind,
            .diary
        )
    }

    func testCarryOverLinesPerKind() {
        let answeredAt = ISO8601DateFormatter().date(from: "2026-05-01T15:00:00Z")
        let answered = EntryDetails(prayerStatus: .answered, answeredAt: answeredAt)
        XCTAssertEqual(
            answered.carryOverLines(from: .prayer, timeZoneIdentifier: "Asia/Seoul"),
            "기도 상태: 응답됨 (2026-05-02)")
        XCTAssertEqual(
            EntryDetails(prayerStatus: .answered)
                .carryOverLines(from: .prayer, timeZoneIdentifier: nil),
            "기도 상태: 응답됨")
        XCTAssertEqual(
            EntryDetails(prayerStatus: .ongoing)
                .carryOverLines(from: .prayer, timeZoneIdentifier: nil),
            "기도 상태: 기도 중")
        XCTAssertNil(EntryDetails().carryOverLines(from: .prayer, timeZoneIdentifier: nil))
        XCTAssertEqual(
            EntryDetails(scriptureReference: "요 3:16")
                .carryOverLines(from: .bibleStudy, timeZoneIdentifier: nil),
            "본문: 요 3:16")
        XCTAssertEqual(
            EntryDetails(bookTitle: "고백록", bookAuthor: "아우구스티누스")
                .carryOverLines(from: .reading, timeZoneIdentifier: nil),
            "책: 고백록 / 저자: 아우구스티누스")
        XCTAssertEqual(
            EntryDetails(bookTitle: "고백록")
                .carryOverLines(from: .reading, timeZoneIdentifier: nil),
            "책: 고백록")
        XCTAssertEqual(
            EntryDetails(bookAuthor: "아우구스티누스")
                .carryOverLines(from: .reading, timeZoneIdentifier: nil),
            "저자: 아우구스티누스")
        XCTAssertEqual(
            EntryDetails(mood: "평안").carryOverLines(from: .diary, timeZoneIdentifier: nil),
            "기분: 평안")
        XCTAssertNil(
            EntryDetails(mood: "평안").carryOverLines(from: .memo, timeZoneIdentifier: nil))
        XCTAssertNil(
            EntryDetails(bookTitle: "  ", bookAuthor: " ")
                .carryOverLines(from: .reading, timeZoneIdentifier: nil))
        XCTAssertEqual(
            EntryDetails(bookTitle: "  ", bookAuthor: "아우구스티누스")
                .carryOverLines(from: .reading, timeZoneIdentifier: nil),
            "저자: 아우구스티누스")
    }
}
#endif
