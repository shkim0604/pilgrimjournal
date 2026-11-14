#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

@MainActor
final class GroupsContentComposerTests: XCTestCase {
    private func composer(
        _ fixture: GroupsContentFixture, draft: GroupPostDraft = GroupPostDraft(),
        groupID: UUID?? = nil
    ) -> GroupComposerModel {
        GroupComposerModel(
            api: fixture.api, groups: [fixture.wednesday, fixture.books],
            groupID: groupID ?? .some(fixture.wednesday.id), draft: draft,
            now: { [clock = fixture.clock] in clock.now }, timeZone: GroupsContentFixture.seoul,
            language: "ko", events: fixture.events)
    }

    func testPrayerNeedsALineAndRespectsLimits() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        XCTAssertEqual(model.items.count, 1, "starts with one empty line")
        XCTAssertTrue(model.issues.contains(.itemsRequired))
        XCTAssertFalse(model.canSubmit)

        model.items[0].text = "가족의 건강"
        XCTAssertEqual(model.issues, [])
        XCTAssertTrue(model.canSubmit)

        model.items = (0..<11).map { GroupComposerItem(text: "기도 \($0)") }
        XCTAssertTrue(model.issues.contains(.tooManyItems))
        model.items = [GroupComposerItem(text: String(repeating: "가", count: 201))]
        XCTAssertTrue(model.issues.contains(.itemTooLong))
        model.items = [GroupComposerItem(text: "기도", who: String(repeating: "나", count: 31))]
        XCTAssertTrue(model.issues.contains(.whoTooLong))
        model.items = [GroupComposerItem(text: "기도")]
        model.title = String(repeating: "제", count: 81)
        XCTAssertTrue(model.issues.contains(.titleTooLong))
        model.title = ""
        model.body = String(repeating: "본", count: 2_001)
        XCTAssertTrue(model.issues.contains(.bodyTooLong))
    }

    func testAddItemStopsAtTen() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        for _ in 0..<12 { model.addItem() }
        XCTAssertEqual(model.items.count, 10)
        XCTAssertEqual(model.notice, GroupComposerIssue.tooManyItems.message)
    }

    func testBookReportAndTestimonyRequireTheirFields() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture, draft: GroupPostDraft(kind: .bookReport))
        XCTAssertEqual(model.issues, [.bookTitleRequired, .bodyRequired])
        model.bookTitle = "고백록"
        model.quote = "주님 안에서 쉬기까지"
        XCTAssertEqual(model.issues, [], "a quote alone is a body")
        XCTAssertEqual(model.composedBody, "> 주님 안에서 쉬기까지")
        model.bookAuthor = String(repeating: "저", count: 61)
        XCTAssertTrue(model.issues.contains(.bookAuthorTooLong))

        model.kind = .testimony
        model.quote = ""
        XCTAssertEqual(model.issues, [.bodyRequired])
        model.body = "감사한 일"
        XCTAssertEqual(model.issues, [])
        XCTAssertNil(model.request(mediaIDs: []).book)
    }

    func testDeadlineAndVisibleDaysAreMutuallyExclusive() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        model.items[0].text = "기도"

        var request = model.request(mediaIDs: [])
        XCTAssertNil(request.deadline)
        XCTAssertEqual(request.visibleDays, 7, "default visible period")

        model.visibleDays = 14
        model.usesDeadline = true
        model.deadlineDate = GroupsContentFixture.start + 6 * 86_400
        request = model.request(mediaIDs: [])
        XCTAssertNil(request.visibleDays)
        XCTAssertEqual(
            request.deadline,
            LocalDate(GroupsContentFixture.start, in: GroupsContentFixture.seoul).adding(days: 6))

        model.kind = .testimony
        model.body = "간증"
        request = model.request(mediaIDs: [])
        XCTAssertNil(request.deadline)
        XCTAssertNil(request.visibleDays)
        XCTAssertNil(request.items)
    }

    func testExpiryPreviewFollowsThePolicy() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        model.items[0].text = "기도"
        model.visibleDays = 14
        XCTAssertEqual(model.expiryPreview, GroupsContentFixture.start + 14 * 86_400)

        let deadline = LocalDate(GroupsContentFixture.start, in: GroupsContentFixture.seoul)
            .adding(days: 6)
        model.usesDeadline = true
        model.deadlineDate = deadline.startOfDay(in: GroupsContentFixture.seoul) + 3_600
        XCTAssertEqual(
            model.expiryPreview, deadline.adding(days: 4).startOfDay(in: GroupsContentFixture.seoul)
        )

        model.deadlineDate = GroupsContentFixture.start - 2 * 86_400
        XCTAssertNil(model.expiryPreview)
        XCTAssertTrue(model.issues.contains(.deadline(.deadlineInPast)))
        model.deadlineDate = GroupsContentFixture.start + 400 * 86_400
        XCTAssertTrue(model.issues.contains(.deadline(.deadlineTooFar)))

        model.kind = .bookReport
        XCTAssertEqual(model.expiryPreview, GroupsContentFixture.start + 7 * 86_400)
    }

    func testPhotosStopAtFour() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        let jpeg = try GroupsContentFixture.jpeg(width: 40, height: 30)
        model.addPhotos(Array(repeating: jpeg, count: 3))
        XCTAssertNil(model.notice)
        model.addPhotos([jpeg, jpeg])
        XCTAssertEqual(model.photos.count, 4)
        XCTAssertEqual(model.notice, "사진은 4장까지 붙일 수 있어요")
        XCTAssertFalse(model.canAddPhotos)

        let prefilled = composer(
            fixture,
            draft: GroupPostDraft(kind: .testimony, photos: Array(repeating: jpeg, count: 5)))
        XCTAssertEqual(prefilled.photos.count, 4)
    }

    func testPrefillFromAnEntry() async throws {
        let fixture = try await GroupsContentFixture()
        let deadline = LocalDate(GroupsContentFixture.start, in: GroupsContentFixture.seoul)
            .adding(days: 3)
        let model = composer(
            fixture,
            draft: GroupPostDraft(
                kind: .prayer, title: "이번 주",
                items: [
                    PrayerItem(text: "면접", topic: "work"),
                    PrayerItem(text: "수술 회복", topic: "health", who: "어머니"),
                ],
                deadline: deadline),
            groupID: .some(nil))
        XCTAssertNil(model.groupID, "two groups: the user picks one")
        XCTAssertTrue(model.issues.contains(.noGroup))
        model.groupID = fixture.wednesday.id
        XCTAssertTrue(model.usesDeadline)
        XCTAssertEqual(model.deadline, deadline)
        XCTAssertEqual(model.filledItems.map(\.topic), ["work", "health"])
        XCTAssertTrue(model.needsOthersConfirmation, "a line names someone else")
    }

    func testSubmitUploadsPhotosAndPosts() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()
        let model = composer(fixture, draft: GroupPostDraft(kind: .testimony, body: "응답받은 기도"))
        model.addPhotos([try GroupsContentFixture.jpeg(width: 120, height: 80)])

        let submitted = await model.submit()
        let post = try XCTUnwrap(submitted)
        XCTAssertEqual(post.kind, .testimony)
        XCTAssertEqual(post.media.count, 1)
        XCTAssertEqual(post.media.first?.width, 120)
        XCTAssertEqual(feed.posts.first?.id, post.id, "the feed shows the new post at once")
        let fetched = try await fixture.api.post(id: post.id)
        XCTAssertEqual(fetched.body, "응답받은 기도")
    }

    func testFailedSubmitKeepsTheDraftAndTheClientID() async throws {
        let fixture = try await GroupsContentFixture()
        let signedOut = PreviewGroupAPI(seeded: true, signedIn: false)
        let model = GroupComposerModel(
            api: signedOut, groups: [fixture.wednesday], groupID: fixture.wednesday.id,
            draft: GroupPostDraft(kind: .testimony, title: "제목", body: "내용"),
            timeZone: GroupsContentFixture.seoul, events: nil)
        model.addPhotos([try GroupsContentFixture.jpeg(width: 20, height: 20)])
        let clientID = model.clientID
        let photoID = model.photos.first?.id

        let result = await model.submit()
        XCTAssertNil(result)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.title, "제목")
        XCTAssertEqual(model.body, "내용")
        XCTAssertEqual(model.photos.first?.id, photoID, "same upload clientId on retry")
        XCTAssertEqual(model.clientID, clientID, "same post clientId on retry")
        XCTAssertEqual(model.request(mediaIDs: []).clientId, clientID)
    }

    func testRetryWithTheSameClientIDMakesOnePost() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture, draft: GroupPostDraft(kind: .testimony, body: "한 번만"))
        let request = model.request(mediaIDs: [])
        // The first attempt reached the server but its response was lost.
        let lost = try await fixture.api.createPost(groupID: fixture.wednesday.id, request)

        let submitted = await model.submit()
        let retried = try XCTUnwrap(submitted)
        XCTAssertEqual(retried.id, lost.id)
        let matching = try await fixture.posts(in: fixture.wednesday).filter { $0.body == "한 번만" }
        XCTAssertEqual(matching.count, 1)
    }

    func testChangingTheGroupStartsANewClientID() async throws {
        let fixture = try await GroupsContentFixture()
        let model = composer(fixture)
        model.addPhotos([try GroupsContentFixture.jpeg(width: 20, height: 20)])
        let clientID = model.clientID
        let photoID = model.photos.first?.id
        model.groupID = fixture.books.id
        XCTAssertNotEqual(model.clientID, clientID)
        XCTAssertNotEqual(model.photos.first?.id, photoID)
    }

    func testPendingDeletionGroupsAreNotOffered() async throws {
        let fixture = try await GroupsContentFixture()
        var closing = fixture.books
        closing.status = .pendingDeletion
        let model = GroupComposerModel(
            api: fixture.api, groups: [fixture.wednesday, closing], groupID: closing.id,
            events: nil)
        XCTAssertEqual(model.groups.map(\.id), [fixture.wednesday.id])
        XCTAssertEqual(model.groupID, fixture.wednesday.id, "the only writable group")
    }
}
#endif
