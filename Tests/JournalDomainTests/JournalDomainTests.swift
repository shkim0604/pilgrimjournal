#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class JournalDomainTests: XCTestCase {
    func testManualEntryRequiresConcreteKind() throws {
        let draft = JournalEntryDraft(kind: .unclassified, body: "본문")
        XCTAssertThrowsError(try draft.validated(manual: true)) { error in
            XCTAssertEqual(error as? JournalError, .invalidManualKind)
        }
    }

    func testMemoCanBeCreatedManuallyAndHasNoTypeSpecificDetails() throws {
        XCTAssertTrue(JournalKind.memo.canCreateManually)
        XCTAssertEqual(JournalKind.memo.localizedName, "메모")

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
}
#endif
