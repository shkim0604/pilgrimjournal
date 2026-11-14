#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class GroupStoreTests: XCTestCase {
    private let groupID = UUID()
    private let now = Fixture.now

    /// Posts one minute apart, newest first: index 0 is `now - 1 min`.
    private func posts(_ count: Int, startingMinutesAgo start: Int = 1) -> [PostResponse] {
        (0..<count).map {
            Fixture.post(groupID: groupID, createdAt: now - Double((start + $0) * 60))
        }
    }

    func testPagesMergeNewestFirstWithoutDuplicates() {
        var store = GroupStore()
        let all = posts(5)

        store.applyFirstPage(
            Page(items: Array(all[0..<3]), nextCursor: "c1"), groupID: groupID, now: now)
        // The server's next page overlaps by one (a post moved between requests).
        store.applyNextPage(
            Page(items: Array(all[2..<5]), nextCursor: nil), groupID: groupID, now: now)

        XCTAssertEqual(store.posts(groupID: groupID, now: now).map(\.id), all.map(\.id))
        XCTAssertEqual(store.feed(groupID: groupID)?.hasMore, false)
        XCTAssertEqual(store.feed(groupID: groupID)?.isLoaded, true)
    }

    func testRefreshingTheFirstPageKeepsOlderPagesAndDropsDeletedPosts() {
        var store = GroupStore()
        let old = posts(6)
        store.applyFirstPage(
            Page(items: Array(old[0..<3]), nextCursor: "c1"), groupID: groupID, now: now)
        store.applyNextPage(
            Page(items: Array(old[3..<6]), nextCursor: "c2"), groupID: groupID, now: now)

        // A new post arrived and old[1] was deleted on the server.
        let newest = Fixture.post(groupID: groupID, createdAt: now)
        store.applyFirstPage(
            Page(items: [newest, old[0], old[2]], nextCursor: "fresh"), groupID: groupID, now: now)

        XCTAssertEqual(
            store.posts(groupID: groupID, now: now).map(\.id),
            [newest.id, old[0].id, old[2].id, old[3].id, old[4].id, old[5].id])
        XCTAssertEqual(
            store.feed(groupID: groupID)?.nextCursor, "c2", "older pages keep their cursor")
    }

    func testCompleteFirstPageReplacesTheFeed() {
        var store = GroupStore()
        let old = posts(4)
        store.applyFirstPage(Page(items: old, nextCursor: "c1"), groupID: groupID, now: now)

        store.applyFirstPage(Page(items: [old[0]], nextCursor: nil), groupID: groupID, now: now)

        XCTAssertEqual(store.posts(groupID: groupID, now: now).map(\.id), [old[0].id])
        XCTAssertNil(store.feed(groupID: groupID)?.nextCursor)
    }

    func testExpiredPostsAreHiddenThenRemoved() {
        var store = GroupStore()
        let soon = Fixture.post(groupID: groupID, createdAt: now - 60, expiresAt: now + 30)
        let later = Fixture.post(groupID: groupID, createdAt: now - 120, expiresAt: now + 3_600)
        store.applyFirstPage(
            Page(items: [soon, later], nextCursor: nil), groupID: groupID, now: now)
        store.upsertPost(soon)
        store.applyFirstCommentPage(
            Page(items: [Fixture.comment(postID: soon.id, createdAt: now, author: Fixture.author)]),
            postID: soon.id)

        XCTAssertEqual(store.nextExpiry(after: now), now + 30)
        XCTAssertNotNil(store.post(id: soon.id, now: now))
        XCTAssertNil(store.post(id: soon.id, now: now + 30), "expiresAt <= now is gone")
        XCTAssertEqual(store.posts(groupID: groupID, now: now + 30).map(\.id), [later.id])

        let removed = store.removeExpired(now: now + 30)

        XCTAssertEqual(removed, [soon.id])
        XCTAssertEqual(store.feed(groupID: groupID)?.posts.map(\.id), [later.id])
        XCTAssertNil(store.thread(postID: soon.id))
        XCTAssertEqual(store.nextExpiry(after: now + 30), now + 3_600)
    }

    func testFirstPageSkipsAlreadyExpiredItems() {
        var store = GroupStore()
        let expired = Fixture.post(groupID: groupID, createdAt: now - 60, expiresAt: now)
        store.applyFirstPage(Page(items: [expired], nextCursor: nil), groupID: groupID, now: now)
        XCTAssertEqual(store.feed(groupID: groupID)?.posts, [])
    }

    func testUnreadCountsAndMarkSeen() {
        var store = GroupStore()
        let other = UUID()
        store.replaceGroups([
            Fixture.group(id: groupID, unread: 3), Fixture.group(id: other, unread: 2),
        ])
        store.applyFirstPage(
            Page(items: [Fixture.post(groupID: groupID, createdAt: now, isUnread: true)]),
            groupID: groupID, now: now)

        XCTAssertEqual(store.totalUnreadCount, 5)
        store.markSeen(groupID: groupID)

        XCTAssertEqual(store.unreadCount(groupID: groupID), 0)
        XCTAssertEqual(store.totalUnreadCount, 2)
        XCTAssertEqual(store.posts(groupID: groupID, now: now).first?.isUnread, false)
    }

    func testGroupsThatDisappearTakeTheirContent() {
        var store = GroupStore()
        let other = UUID()
        store.replaceGroups([Fixture.group(id: groupID), Fixture.group(id: other)])
        let post = Fixture.post(groupID: groupID, createdAt: now)
        store.applyFirstPage(Page(items: [post]), groupID: groupID, now: now)

        store.replaceGroups([Fixture.group(id: other, name: "새 이름")])

        XCTAssertNil(store.feed(groupID: groupID))
        XCTAssertNil(store.post(id: post.id, now: now))
        XCTAssertEqual(store.groups.map(\.name), ["새 이름"])
        store.removeGroup(id: other)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testUpsertedPostLandsInOrder() {
        var store = GroupStore()
        let existing = posts(2, startingMinutesAgo: 5)
        store.applyFirstPage(Page(items: existing), groupID: groupID, now: now)

        let created = Fixture.post(groupID: groupID, createdAt: now)
        store.upsertPost(created)
        var extended = existing[1]
        extended.expiresAt = extended.expiresAt + 7 * 86_400
        extended.extensionCount = 1
        store.upsertPost(extended)

        let feed = store.posts(groupID: groupID, now: now)
        XCTAssertEqual(feed.map(\.id), [created.id, existing[0].id, existing[1].id])
        XCTAssertEqual(feed.last?.extensionCount, 1)
    }

    func testCommentsMergeAndAdjustCounts() {
        var store = GroupStore()
        let post = Fixture.post(groupID: groupID, createdAt: now - 600, commentCount: 2)
        store.applyFirstPage(Page(items: [post]), groupID: groupID, now: now)
        let first = Fixture.comment(postID: post.id, createdAt: now - 300, author: Fixture.author)
        let second = Fixture.comment(postID: post.id, createdAt: now - 200, author: Fixture.author)
        store.applyFirstCommentPage(Page(items: [second, first], nextCursor: "c"), postID: post.id)
        store.applyNextCommentPage(Page(items: [second], nextCursor: nil), postID: post.id)
        XCTAssertEqual(store.comments(postID: post.id).map(\.id), [first.id, second.id])
        XCTAssertEqual(store.thread(postID: post.id)?.hasMore, false)

        let mine = Fixture.comment(
            postID: post.id, createdAt: now,
            author: UserSummary(id: Fixture.userID, displayName: "나"))
        store.upsertComment(mine)
        store.upsertComment(mine) // a retry with the same clientId returns the same comment
        XCTAssertEqual(store.post(id: post.id, now: now)?.commentCount, 3)

        store.removeComment(id: first.id, postID: post.id)
        XCTAssertEqual(store.comments(postID: post.id).map(\.id), [second.id, mine.id])
        XCTAssertEqual(store.post(id: post.id, now: now)?.commentCount, 2)
    }

    func testHidingAPersonRemovesTheirPostsAndComments() {
        var store = GroupStore()
        let hidden = UserSummary(id: UUID(), displayName: "숨김")
        let theirs = Fixture.post(groupID: groupID, createdAt: now, author: hidden)
        let mine = Fixture.post(groupID: groupID, createdAt: now - 60, commentCount: 1)
        store.applyFirstPage(Page(items: [theirs, mine]), groupID: groupID, now: now)
        store.applyFirstCommentPage(
            Page(items: [Fixture.comment(postID: mine.id, createdAt: now, author: hidden)]),
            postID: mine.id)

        store.removeContent(byAuthor: hidden.id)

        XCTAssertEqual(store.posts(groupID: groupID, now: now).map(\.id), [mine.id])
        XCTAssertTrue(store.comments(postID: mine.id).isEmpty)
        XCTAssertEqual(store.post(id: mine.id, now: now)?.commentCount, 0)
    }

    func testReactionsAndRemovalUpdateEveryCopy() {
        var store = GroupStore()
        let post = Fixture.post(groupID: groupID, createdAt: now)
        store.upsertPost(post) // opened from a notification before the feed loaded
        store.applyFirstPage(Page(items: [post]), groupID: groupID, now: now)

        let reactions = [ReactionSummary(key: .emoji("🙏"), count: 2, reactedByMe: true)]
        store.updateReactions(postID: post.id, reactions)
        XCTAssertEqual(store.post(id: post.id, now: now)?.reactions, reactions)
        XCTAssertEqual(store.posts(groupID: groupID, now: now).first?.reactions, reactions)

        store.removePost(id: post.id)
        XCTAssertNil(store.post(id: post.id, now: now))
        XCTAssertTrue(store.posts(groupID: groupID, now: now).isEmpty)
    }
}
#endif
