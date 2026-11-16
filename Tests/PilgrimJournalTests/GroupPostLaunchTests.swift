#if canImport(XCTest)
import Foundation
import JournalDomain
import JournalGroups
import JournalShareDrafts
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

@MainActor
final class GroupPostLaunchTests: XCTestCase {
    nonisolated private static let seoul = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-10-15 09:00 KST, a Thursday.
    nonisolated private static let thursdayMorning = Date(timeIntervalSince1970: 1_792_022_400)

    private static var seoulCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar
    }

    private func entry(
        kind: JournalKind = .diary, title: String = "", body: String,
        details: EntryDetails = EntryDetails(), isDeleted: Bool = false
    ) -> JournalEntryRecord {
        var record = JournalEntryRecord(
            id: UUID(), kind: kind, title: title, body: body,
            occurredAt: Self.thursdayMorning, originalTimeZone: "Asia/Seoul", tags: [],
            isStarred: false, isPinned: false, details: details, sourceUUID: nil,
            sourceMetadata: nil, currentRevisionID: UUID(), updatedAt: Self.thursdayMorning,
            modifiedByDeviceID: "test")
        if isDeleted { record.deletedAt = Self.thursdayMorning }
        return record
    }

    private func row(
        _ text: String, who: String? = nil, topic: PrayerRequestTopic? = nil,
        selected: Bool = true
    ) -> PrayerRequestShareModel.Row {
        PrayerRequestShareModel.Row(
            id: UUID(), text: text, language: .korean, topic: topic, who: who,
            isSelected: selected, isEdited: false)
    }

    // MARK: Entry → book report / testimony

    func testReadingNoteBecomesABookReportWithItsBook() {
        var details = EntryDetails()
        details.bookTitle = " 고백록 "
        details.bookAuthor = "아우구스티누스"
        let draft = EntryGroupPostDraft.draft(
            for: entry(
                kind: .reading, title: "다시 읽은 고백록", body: "쉼을 얻기까지\n\n", details: details),
            photos: [Data([1]), Data([2])])
        XCTAssertEqual(draft.kind, .bookReport)
        XCTAssertEqual(draft.title, "다시 읽은 고백록")
        XCTAssertEqual(draft.bookTitle, "고백록")
        XCTAssertEqual(draft.bookAuthor, "아우구스티누스")
        XCTAssertEqual(draft.body, "쉼을 얻기까지")
        XCTAssertEqual(draft.photos, [Data([1]), Data([2])])
        XCTAssertTrue(draft.items.isEmpty)
        XCTAssertNil(draft.deadline)
    }

    func testOtherKindsBecomeTestimoniesWithoutBookInfo() {
        var details = EntryDetails()
        details.bookTitle = "남은 책 제목"
        for kind in [JournalKind.diary, .prayer, .memo, .bibleStudy] {
            let draft = EntryGroupPostDraft.draft(
                for: entry(kind: kind, body: "응답받은 기도", details: details), photos: [])
            XCTAssertEqual(draft.kind, .testimony, kind.id)
            XCTAssertEqual(draft.bookTitle, "", kind.id)
            XCTAssertEqual(draft.body, "응답받은 기도", kind.id)
        }
    }

    func testInlineImageLinesLeaveTheTextAndLeadThePhotos() {
        let first = UUID()
        let second = UUID()
        let body = """
            첫 문단

            ![](attachment:\(second.uuidString) =300x200)

            둘째 문단
            ![](attachment:\(first.uuidString))
            """
        XCTAssertEqual(EntryGroupPostDraft.text(of: body), "첫 문단\n\n둘째 문단")

        let other = attachment(mime: "image/png")
        let pdf = attachment(mime: "application/pdf")
        let deleted = attachment(mime: "image/jpeg", deleted: true)
        let ids = EntryGroupPostDraft.photoAttachmentIDs(
            body: body,
            attachments: [
                other, pdf, deleted, attachment(id: first, mime: "image/jpeg"),
                attachment(id: second, mime: "IMAGE/HEIC"),
            ])
        XCTAssertEqual(ids, [second, first, other.id], "inline in text order, then the rest")
    }

    func testEntriesWithoutTextOrInTheTrashAreNotOffered() {
        XCTAssertTrue(entry(body: "감사").offersGroupPosting)
        XCTAssertFalse(entry(body: " \n ").offersGroupPosting)
        XCTAssertFalse(entry(body: "감사", isDeleted: true).offersGroupPosting)
    }

    private func attachment(id: UUID = UUID(), mime: String, deleted: Bool = false)
        -> AttachmentRecord
    {
        AttachmentRecord(
            id: id, entryID: UUID(), originalName: "photo", mimeType: mime, checksum: "x",
            byteCount: 1, deletedAt: deleted ? Self.thursdayMorning : nil)
    }

    // MARK: Prayer-request sheet → prayer post

    func testSelectedLinesBecomeItemsWithTheirLabels() {
        let items = PrayerRequestGroupDraft.items(from: [
            row(" 어머니가 회복하시도록 ", who: "어머니", topic: .health),
            row("시험을 잘 준비하도록", who: "나", topic: .study),
            row("고르지 않은 줄", selected: false),
            row("   "),
            row("친구의 이사를 위해", who: "Me"),
        ])
        XCTAssertEqual(
            items,
            [
                PrayerItem(text: "어머니가 회복하시도록", topic: "health", who: "어머니"),
                PrayerItem(text: "시험을 잘 준비하도록", topic: "study", who: nil),
                PrayerItem(text: "친구의 이사를 위해", topic: nil, who: nil),
            ])
    }

    func testDeadlineIsSuggestedFromTheLines() {
        let draft = PrayerRequestGroupDraft.draft(
            rows: [row("다음 주 금요일 면접을 잘 보도록"), row("가족의 건강")],
            entryBody: "다음 달 12일에 이사한다.", writtenAt: Self.thursdayMorning,
            entryTimeZone: Self.seoul, now: Self.thursdayMorning, calendar: Self.seoulCalendar)
        XCTAssertEqual(draft.kind, .prayer)
        XCTAssertEqual(draft.items.count, 2)
        XCTAssertEqual(draft.deadline, LocalDate(year: 2026, month: 10, day: 23))
    }

    func testDeadlineFallsBackToTheEntryThenToTheVisiblePeriod() {
        let fromEntry = PrayerRequestGroupDraft.draft(
            rows: [row("친구의 수술이 잘 되도록")],
            entryBody: "친구가 11월 20일에 수술을 받는다.", writtenAt: Self.thursdayMorning,
            entryTimeZone: Self.seoul, now: Self.thursdayMorning, calendar: Self.seoulCalendar)
        XCTAssertEqual(fromEntry.deadline, LocalDate(year: 2026, month: 11, day: 20))

        let none = PrayerRequestGroupDraft.draft(
            rows: [row("마음의 평안")], entryBody: "조용한 하루.", writtenAt: Self.thursdayMorning,
            entryTimeZone: Self.seoul, now: Self.thursdayMorning, calendar: Self.seoulCalendar)
        XCTAssertNil(none.deadline)
        XCTAssertEqual(none.visibleDays, PostExpiryPolicy.defaultVisibleDays)

        // Opened a month later, last month's "내일" is past: no deadline.
        let late = PrayerRequestGroupDraft.draft(
            rows: [row("내일 면접")], entryBody: "", writtenAt: Self.thursdayMorning,
            entryTimeZone: Self.seoul, now: Self.thursdayMorning.addingTimeInterval(30 * 86_400),
            calendar: Self.seoulCalendar)
        XCTAssertNil(late.deadline)
    }

    func testComposerOpensWithTheSuggestionAndAsksAboutOthers() async throws {
        let api = PreviewGroupAPI(now: { Self.thursdayMorning })
        let groups = try await api.groups()
        let draft = PrayerRequestGroupDraft.draft(
            rows: [row("어머니가 11월 20일 수술을 잘 받으시도록", who: "어머니", topic: .health)],
            entryBody: "", writtenAt: Self.thursdayMorning, entryTimeZone: Self.seoul,
            now: Self.thursdayMorning, calendar: Self.seoulCalendar)
        let composer = GroupComposerModel(
            api: api, groups: groups, groupID: groups.first?.id, draft: draft,
            now: { Self.thursdayMorning }, timeZone: Self.seoul, language: "ko", events: nil)
        XCTAssertEqual(composer.kind, .prayer)
        XCTAssertTrue(composer.usesDeadline)
        XCTAssertEqual(composer.deadline, LocalDate(year: 2026, month: 11, day: 20))
        XCTAssertNil(composer.requestVisibleDays)
        XCTAssertTrue(composer.needsOthersConfirmation, "a line about someone else is confirmed")
        XCTAssertEqual(composer.issues, [])
        XCTAssertNil(composer.postedPost, "nothing is posted until 올리기")
    }

    // MARK: Readiness

    private func group(_ status: GroupStatus) -> GroupSummary {
        GroupSummary(
            id: UUID(), name: "수요 기도모임", status: status, memberCount: 3, isAdmin: true,
            admin: nil, unreadCount: 0, latestPostAt: nil,
            notifications: GroupNotificationSettings())
    }

    func testReadinessExplainsEachBlockedState() {
        let evaluate = { (state: GroupsAccountState, groups: [GroupSummary]) in
            GroupPostReadiness.evaluate(accountState: state, groups: groups, lastError: nil)
        }
        XCTAssertEqual(evaluate(.signedIn, [group(.active)]), .ready)
        XCTAssertEqual(evaluate(.signedIn, [group(.pendingDeletion), group(.voting)]), .ready)
        XCTAssertNotEqual(evaluate(.signedIn, [group(.pendingDeletion)]), .ready)
        XCTAssertNotEqual(evaluate(.signedIn, []), .ready)
        XCTAssertEqual(
            evaluate(.upgradeRequired, [group(.active)]), .blocked(GroupMessages.upgradeRequired))
        // Not signed in (or signed up) to groups: onboarding opens from the share flow itself.
        XCTAssertEqual(evaluate(.signedOut, [group(.active)]), .needsOnboarding)
        XCTAssertEqual(evaluate(.needsProfile, []), .needsOnboarding)
        for state in [GroupsAccountState.signedOut, .needsProfile, .needsSubscription, .unknown] {
            XCTAssertNotEqual(evaluate(state, [group(.active)]), .ready, "\(state)")
        }
        XCTAssertNotEqual(
            GroupPostReadiness.evaluate(accountState: .signedIn, groups: [], lastError: .offline),
            evaluate(.signedIn, []), "no list because offline is not 'no groups'")
    }

    func testPreparingLoadsTheAccountAndGroups() async {
        let signedIn = GroupsMembershipFixtures.controller(api: PreviewGroupAPI())
        let readiness = await signedIn.prepareForPosting()
        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(signedIn.accountState, .signedIn)
        XCTAssertFalse(signedIn.groups.isEmpty)

        let noGroups = GroupsMembershipFixtures.controller(api: PreviewGroupAPI(seeded: false))
        let noGroupsReadiness = await noGroups.prepareForPosting()
        XCTAssertNotEqual(noGroupsReadiness, .ready)

        let signedOut = GroupsMembershipFixtures.controller(api: PreviewGroupAPI(signedIn: false))
        let signedOutReadiness = await signedOut.prepareForPosting()
        XCTAssertEqual(signedOutReadiness, .needsOnboarding)
        XCTAssertEqual(signedOut.accountState, .signedOut)
    }
}
#endif
