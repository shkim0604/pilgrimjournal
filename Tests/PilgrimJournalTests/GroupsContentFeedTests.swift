#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import UniformTypeIdentifiers
import XCTest

/// A clock tests move by hand; shared by `PreviewGroupAPI` and the models.
final class GroupsContentClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

/// The seeded preview world plus helpers the content tests share.
@MainActor
struct GroupsContentFixture {
    /// 2025-11-14 09:20 KST.
    nonisolated static let start = Date(timeIntervalSince1970: 1_763_079_600)
    nonisolated static let seoul = TimeZone(identifier: "Asia/Seoul")!

    let clock: GroupsContentClock
    let api: PreviewGroupAPI
    let events = GroupContentEvents()
    /// 수요 기도모임: the user is admin; three posts (prayer, book report, testimony).
    let wednesday: GroupSummary
    /// 청년부 독서모임: someone else is admin; one book report.
    let books: GroupSummary

    init() async throws {
        let clock = GroupsContentClock(Self.start)
        self.clock = clock
        api = PreviewGroupAPI(now: { clock.now })
        let groups = try await api.groups()
        wednesday = try XCTUnwrap(groups.first { $0.name == "수요 기도모임" })
        books = try XCTUnwrap(groups.first { $0.name == "청년부 독서모임" })
    }

    func posts(in group: GroupSummary) async throws -> [PostResponse] {
        try await api.posts(groupID: group.id, cursor: nil, limit: 50).items
    }

    func post(_ kind: PostKind, in group: GroupSummary) async throws -> PostResponse {
        let all = try await posts(in: group)
        return try XCTUnwrap(all.first { $0.kind == kind })
    }

    func feed(_ group: GroupSummary, pageSize: Int = 20) -> GroupFeedModel {
        GroupFeedModel(
            api: api, groupID: group.id, now: { [clock] in clock.now }, pageSize: pageSize,
            events: events)
    }

    nonisolated static func testimony(_ body: String) -> CreatePostRequest {
        CreatePostRequest(
            clientId: UUID(), kind: .testimony, body: body, timeZone: seoul.identifier)
    }

    /// A plain JPEG the preview server accepts.
    nonisolated static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// Counts poll sleeps and keeps each one short.
actor GroupsContentSleepCounter {
    private(set) var count = 0

    func sleep() async throws {
        count += 1
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
final class GroupsContentFeedTests: XCTestCase {
    func testFirstPageThenCursorPaging() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday, pageSize: 2)

        await feed.refresh()
        XCTAssertEqual(feed.loadState, .loaded)
        XCTAssertEqual(feed.posts.count, 2)
        XCTAssertTrue(feed.hasMore)

        await feed.loadMore()
        XCTAssertEqual(feed.posts.map(\.kind), [.testimony, .prayer, .bookReport])
        XCTAssertFalse(feed.hasMore)

        await feed.loadMore()
        XCTAssertEqual(feed.posts.count, 3, "no cursor, no request")
    }

    func testRefreshMergesNewPostsAboveLoadedPages() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday, pageSize: 2)
        await feed.refresh()
        await feed.loadMore()
        let author = try await fixture.post(.prayer, in: fixture.wednesday).author

        fixture.clock.advance(by: 60)
        let newID = try await fixture.api.simulatePost(
            groupID: fixture.wednesday.id, authorID: author.id,
            GroupsContentFixture.testimony("새 간증"))
        await feed.refresh()

        XCTAssertEqual(feed.posts.first?.id, newID)
        XCTAssertEqual(feed.posts.count, 4, "older pages stay below the refreshed first page")
        XCTAssertEqual(Set(feed.posts.map(\.id)).count, 4, "no duplicates")
        XCTAssertFalse(feed.hasMore)
    }

    func testRefreshDropsPostsTheServerNoLongerReturns() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()
        let testimony = try XCTUnwrap(feed.posts.first { $0.kind == .testimony })

        try await fixture.api.deletePost(id: testimony.id)
        await feed.refresh()

        XCTAssertFalse(feed.posts.contains { $0.id == testimony.id })
    }

    func testExpiredPostsAreHiddenBeforeTheNextRefresh() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()
        let report = try XCTUnwrap(feed.posts.first { $0.kind == .bookReport })

        fixture.clock.now = report.expiresAt
        XCTAssertFalse(feed.posts.contains { $0.id == report.id }, "expiresAt is exclusive")
        XCTAssertTrue(feed.loadedPosts.contains { $0.id == report.id }, "not refreshed yet")

        await feed.refresh()
        XCTAssertFalse(feed.loadedPosts.contains { $0.id == report.id })
    }

    func testKindFilter() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()

        feed.kindFilter = .bookReport
        XCTAssertEqual(feed.posts.map(\.kind), [.bookReport])
        feed.kindFilter = .prayer
        XCTAssertEqual(feed.posts.map(\.kind), [.prayer])
        feed.kindFilter = nil
        XCTAssertEqual(feed.posts.count, 3)
    }

    func testFailedFirstLoadShowsOfflineStateAndKeepsPostsOnLaterFailures() async throws {
        let api = PreviewGroupAPI(seeded: true, signedIn: false)
        let feed = GroupFeedModel(api: api, groupID: UUID(), events: nil)
        await feed.refresh()
        XCTAssertEqual(
            feed.loadState, .failed(GroupContentError.message(for: GroupAPIError.notSignedIn)))
        XCTAssertEqual(
            GroupContentError.message(for: GroupAPIError.offline),
            "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요")
    }

    func testPollingRefreshesUntilCancelled() async throws {
        let fixture = try await GroupsContentFixture()
        let counter = GroupsContentSleepCounter()
        let feed = GroupFeedModel(
            api: fixture.api, groupID: fixture.wednesday.id,
            now: { [clock = fixture.clock] in clock.now },
            sleep: { _ in try await counter.sleep() }, events: nil)
        await feed.refresh()
        let author = try await fixture.post(.prayer, in: fixture.wednesday).author

        let polling = Task { await feed.pollWhileVisible() }
        let first = try await fixture.api.simulatePost(
            groupID: fixture.wednesday.id, authorID: author.id,
            GroupsContentFixture.testimony("폴링 중 새 글"))
        try await waitUntil { feed.posts.contains { $0.id == first } }
        XCTAssertTrue(feed.isPolling)

        polling.cancel()
        await polling.value
        XCTAssertFalse(feed.isPolling)
        let sleepsAtCancel = await counter.count

        let second = try await fixture.api.simulatePost(
            groupID: fixture.wednesday.id, authorID: author.id,
            GroupsContentFixture.testimony("멈춘 뒤 새 글"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(feed.posts.contains { $0.id == second }, "no refresh after cancellation")
        let sleepsLater = await counter.count
        XCTAssertEqual(sleepsLater, sleepsAtCancel)
    }

    func testEventsUpdateTheFeedAtOnce() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()
        let prayer = try XCTUnwrap(feed.posts.first { $0.kind == .prayer })

        fixture.events.send(.postRemoved(postID: prayer.id))
        XCTAssertFalse(feed.posts.contains { $0.id == prayer.id })

        let report = try XCTUnwrap(feed.posts.first { $0.kind == .bookReport })
        fixture.events.send(.authorHidden(userID: report.author.id))
        XCTAssertFalse(feed.posts.contains { $0.author.id == report.author.id })

        var other = report
        other.id = UUID()
        other.groupId = fixture.books.id
        fixture.events.send(.postCreated(other))
        XCTAssertFalse(feed.posts.contains { $0.id == other.id }, "another group's post")
    }

    func testStartMarksTheGroupSeen() async throws {
        let fixture = try await GroupsContentFixture()
        let groupsBefore = try await fixture.api.groups()
        let before = try XCTUnwrap(groupsBefore.first { $0.id == fixture.wednesday.id })
        XCTAssertGreaterThan(before.unreadCount, 0)

        await fixture.feed(fixture.wednesday).start()

        let groupsAfter = try await fixture.api.groups()
        let after = try XCTUnwrap(groupsAfter.first { $0.id == fixture.wednesday.id })
        XCTAssertEqual(after.unreadCount, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

final class GroupsContentExpiryTextTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = GroupsContentFixture.seoul
        return calendar
    }

    func testDeadlineCountdown() {
        let now = GroupsContentFixture.start
        let today = LocalDate(now, in: GroupsContentFixture.seoul)
        XCTAssertEqual(
            GroupExpiryText.deadlineCountdown(today.adding(days: 6), now: now, calendar: calendar),
            "D-6")
        XCTAssertEqual(
            GroupExpiryText.deadlineCountdown(today, now: now, calendar: calendar), "D-day")
        XCTAssertEqual(
            GroupExpiryText.daysUntilDeadline(today.adding(days: -1), now: now, calendar: calendar),
            -1)
    }

    func testDisappearanceCountsCalendarDaysThenHours() {
        let now = GroupsContentFixture.start
        XCTAssertEqual(
            GroupExpiryText.disappearance(now + 7 * 86_400, now: now, calendar: calendar),
            "7일 뒤 사라져요")
        XCTAssertEqual(
            GroupExpiryText.disappearance(now + 5 * 3_600, now: now, calendar: calendar),
            "5시간 뒤 사라져요")
        XCTAssertEqual(
            GroupExpiryText.disappearance(now + 600, now: now, calendar: calendar), "곧 사라져요")
        XCTAssertTrue(GroupExpiryText.isEndingSoon(now + 600, now: now))
    }

    func testDeadlinePostIsVisibleUntilThreeDaysAfterTheDeadline() throws {
        let deadline = try XCTUnwrap(LocalDate(year: 2025, month: 11, day: 20))
        let expiresAt = try PostExpiryPolicy().expiresAt(
            kind: .prayer, createdAt: GroupsContentFixture.start, deadline: deadline,
            visibleDays: nil, timeZone: GroupsContentFixture.seoul)
        let last = GroupExpiryText.lastVisibleDay(expiresAt, calendar: calendar)
        XCTAssertEqual(LocalDate(last, in: GroupsContentFixture.seoul), deadline.adding(days: 3))
    }

    func testQuoteRoundTrip() {
        let body = GroupPostQuote.compose(quote: "첫 줄\n둘째 줄", body: "느낀 점")
        XCTAssertEqual(body, "> 첫 줄\n> 둘째 줄\n\n느낀 점")
        let parts = GroupPostQuote.split(body)
        XCTAssertEqual(parts.quote, "첫 줄\n둘째 줄")
        XCTAssertEqual(parts.body, "느낀 점")
        XCTAssertNil(GroupPostQuote.split("인용 없음").quote)
    }
}
#endif
