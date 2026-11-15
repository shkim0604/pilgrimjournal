import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// `groups/:id/posts`, `posts/:id`, `posts/:id/extend` against Postgres.
final class PostRoutesTests: DatabaseTestCase {
    // MARK: - Create

    func testCreateEachKindAndRepeatTheClientID() async throws {
        let alice = try await fixtures.user("앨리스")
        let group = try await fixtures.group(admin: alice)

        let clientID = UUID()
        let first = try await createPost(PostRequests.testimony(clientId: clientID), in: group, as: alice)
        XCTAssertEqual(first.status, .created, first.body.string)
        let created = try decode(PostResponse.self, from: first)
        XCTAssertEqual(created.kind, .testimony)
        XCTAssertEqual(created.author.displayName, "앨리스")
        XCTAssertTrue(created.isMine)
        XCTAssertFalse(created.isUnread)
        XCTAssertEqual(created.body, "간증 본문")
        XCTAssertEqual(
            created.expiresAt.timeIntervalSince(created.createdAt), 7 * 86_400, accuracy: 1)

        // Same clientId, different content: the first post again, 200.
        let repeated = try await createPost(
            PostRequests.testimony("다른 내용", clientId: clientID), in: group, as: alice)
        XCTAssertEqual(repeated.status, .ok)
        XCTAssertEqual(try decode(PostResponse.self, from: repeated).id, created.id)
        let count = try await Post.query(on: db).count()
        XCTAssertEqual(count, 1)

        let prayer = try await createPost(PostRequests.prayer(visibleDays: 3), in: group, as: alice)
        XCTAssertEqual(prayer.status, .created, prayer.body.string)
        let prayerPost = try decode(PostResponse.self, from: prayer)
        XCTAssertEqual(prayerPost.items, [PrayerItem(text: "가족의 건강")])
        XCTAssertEqual(prayerPost.visibleDays, 3)
        XCTAssertEqual(
            prayerPost.expiresAt.timeIntervalSince(prayerPost.createdAt), 3 * 86_400, accuracy: 1)

        let book = try await createPost(PostRequests.bookReport(), in: group, as: alice)
        XCTAssertEqual(book.status, .created, book.body.string)
        XCTAssertEqual(try decode(PostResponse.self, from: book).book?.title, "고백록")
    }

    func testCreateValidationAndGroupState() async throws {
        let alice = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)

        try assertError(
            try await createPost(PostRequests.prayer(items: []), in: group, as: alice), 422,
            .validationFailed)
        try assertError(
            try await createPost(PostRequests.testimony(), in: group, as: outsider), 404,
            .notFound)
        let missing = try await send(
            .POST, "groups/\(UUID())/posts", as: alice, json: PostRequests.testimony())
        try assertError(missing, 404, .notFound)

        // Voting still allows posts; pending deletion does not.
        try await setStatus(.voting, of: group)
        assertStatus(
            try await createPost(PostRequests.testimony(), in: group, as: alice), .created)
        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await createPost(PostRequests.testimony(), in: group, as: alice), 409,
            .groupPendingDeletion)
    }

    func testSignUpAndSuspensionGate() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let newcomer = try await fixtures.user(nil)
        try await fixtures.join(newcomer, group)
        try assertError(
            try await send(.GET, "groups/\(try group.requireID())/posts", as: newcomer), 403,
            .signupRequired)

        alice.suspendedAt = Date()
        alice.suspendedUntil = Date().addingTimeInterval(3_600)
        try await alice.save(on: db)
        try assertError(
            try await send(.GET, "groups/\(try group.requireID())/posts", as: alice), 403,
            .accountSuspended)
        alice.suspendedUntil = Date().addingTimeInterval(-1)
        try await alice.save(on: db)
        assertStatus(
            try await send(.GET, "groups/\(try group.requireID())/posts", as: alice), .ok)
    }

    func testPhotosAttachOnceToTheirUploader() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let other = try await fixtures.group(admin: alice)
        let first = try await fixtures.media(uploadedBy: alice, in: group)
        let second = try await fixtures.media(uploadedBy: alice, in: group)

        let response = try await createPost(
            PostRequests.testimony(media: [second.requireID(), first.requireID()]), in: group,
            as: alice)
        XCTAssertEqual(response.status, .created, response.body.string)
        let post = try decode(PostResponse.self, from: response)
        XCTAssertEqual(post.media.map(\.id), [try second.requireID(), try first.requireID()])
        XCTAssertTrue(post.media.allSatisfy { $0.url.absoluteString.contains("sig=") })

        // Already attached, someone else's, another group's, another purpose: 409, nothing saved.
        let bobs = try await fixtures.media(uploadedBy: bob, in: group)
        let otherGroup = try await fixtures.media(uploadedBy: alice, in: other)
        let comment = try await fixtures.media(uploadedBy: alice, in: group, purpose: .comment)
        for id in [try first.requireID(), try bobs.requireID(), try otherGroup.requireID(),
            try comment.requireID()]
        {
            try assertError(
                try await createPost(PostRequests.testimony(media: [id]), in: group, as: alice),
                409, .mediaNotAttachable)
        }
        let count = try await Post.query(on: db).count()
        XCTAssertEqual(count, 1, "failed attachments roll the post back")
    }

    func testNewPostQueuesPushesForTheRightMembers() async throws {
        let author = try await fixtures.user("작성자")
        let plain = try await fixtures.user("멤버")
        let muted = try await fixtures.user("알림 끔")
        let blocker = try await fixtures.user("차단한 사람")
        let blocked = try await fixtures.user("차단된 사람")
        let hider = try await fixtures.user("숨긴 사람")
        let postHider = try await fixtures.user("글 숨김")
        let outsider = try await fixtures.user("외부인")
        let group = try await fixtures.group(
            "수요 기도모임", admin: author,
            members: [plain, muted, blocker, blocked, hider, postHider])
        let mutedMembership = try await ContentVisibility.requireMembership(
            of: try muted.requireID(), in: try group.requireID(), on: db)
        mutedMembership.newPostPushEnabled = false
        try await mutedMembership.save(on: db)
        try await fixtures.block(blocker, author)
        try await fixtures.block(author, blocked)
        try await fixtures.hide(user: author, by: hider)
        // A post hide is about one post, not the author: new posts still notify.
        try await fixtures.hide(post: try await fixtures.post(by: author, in: group), by: postHider)
        _ = outsider

        let response = try await createPost(PostRequests.prayer(), in: group, as: author)
        XCTAssertEqual(response.status, .created, response.body.string)
        let post = try decode(PostResponse.self, from: response)

        let entries = try await PushOutboxEntry.query(on: db).all()
        XCTAssertEqual(
            Set(entries.map { $0.$recipient.id }),
            [try plain.requireID(), try postHider.requireID()])
        for entry in entries {
            XCTAssertEqual(entry.kind, .newPost)
            XCTAssertEqual(entry.payload.pilgrim.postId, post.id)
            XCTAssertEqual(entry.payload.pilgrim.groupId, try group.requireID())
        }
        // The payload never carries the prayer text.
        let json = String(decoding: try PilgrimJSON.encode(entries[0].payload), as: UTF8.self)
        XCTAssertFalse(json.contains("가족의 건강"))
        XCTAssertTrue(json.contains("작성자"))

        // A repeat of the same clientId does not queue again.
        let stored = try await Post.find(post.id, on: db)
        let clientID = try XCTUnwrap(stored).clientID
        assertStatus(
            try await createPost(PostRequests.prayer(clientId: clientID), in: group, as: author),
            .ok)
        let after = try await PushOutboxEntry.query(on: db).count()
        XCTAssertEqual(after, entries.count)
    }

    // MARK: - Feed and detail

    func testFeedPagesNewestFirstWithoutGapsOrRepeats() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        var ids: [UUID] = []
        for _ in 0..<7 { ids.append(try await fixtures.post(by: alice, in: group).requireID()) }
        // Three posts share one timestamp with a sub-millisecond fraction: the id breaks the tie.
        let tied = Date(timeIntervalSince1970: 1_794_625_200.123457)
        try await sql.raw(
            "UPDATE posts SET created_at = \(bind: tied) WHERE id = ANY(\(bind: Array(ids.prefix(3))))"
        ).run()
        _ = try await fixtures.post(
            by: alice, in: group, expiresAt: Date().addingTimeInterval(-1))

        var seen: [UUID] = []
        var cursor: String?
        var pages = 0
        repeat {
            var path = "groups/\(try group.requireID())/posts?limit=2"
            if let cursor { path += "&cursor=\(cursor)" }
            let response = try await send(.GET, path, as: alice)
            XCTAssertEqual(response.status, .ok, response.body.string)
            let page = try decode(APIPage<PostResponse>.self, from: response)
            seen += page.items.map(\.id)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(seen.count, 7)
        XCTAssertEqual(Set(seen), Set(ids), "the expired post is left out")

        let all = try await send(.GET, "groups/\(try group.requireID())/posts", as: alice)
        let items = try decode(APIPage<PostResponse>.self, from: all).items
        XCTAssertEqual(items.map(\.id), seen)
        XCTAssertEqual(
            items.map(\.createdAt), items.map(\.createdAt).sorted(by: >), "newest first")
    }

    func testFeedAndDetailHonourBlocksHidesAndMembership() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let bobPost = try await fixtures.post(by: bob, in: group)
        let alicePost = try await fixtures.post(by: alice, in: group)

        let feedPath = "groups/\(try group.requireID())/posts"
        try assertError(try await send(.GET, feedPath, as: outsider), 404, .notFound)
        try assertError(
            try await send(.GET, "posts/\(try bobPost.requireID())", as: outsider), 404,
            .notFound)

        let detail = try await send(.GET, "posts/\(try bobPost.requireID())", as: alice)
        XCTAssertEqual(detail.status, .ok)
        XCTAssertEqual(try decode(PostResponse.self, from: detail).author.displayName, "밥")

        try await fixtures.block(bob, alice)
        let feed = try decode(APIPage<PostResponse>.self, from: try await send(.GET, feedPath, as: alice))
        XCTAssertEqual(feed.items.map(\.id), [try alicePost.requireID()])
        try assertError(
            try await send(.GET, "posts/\(try bobPost.requireID())", as: alice), 404, .notFound)
    }

    func testUnreadIsOtherPeoplesPostsSinceLastSeen() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let groupID = try group.requireID()
        let membership = try await ContentVisibility.requireMembership(
            of: try alice.requireID(), in: groupID, on: db)
        let old = try await fixtures.post(by: bob, in: group)
        membership.lastSeenAt = Date()
        try await membership.save(on: db)
        let fresh = try await fixtures.post(by: bob, in: group)
        let mine = try await fixtures.post(by: alice, in: group)

        let feed = try decode(
            APIPage<PostResponse>.self, from: try await send(.GET, "groups/\(groupID)/posts", as: alice))
        let unread = Dictionary(uniqueKeysWithValues: feed.items.map { ($0.id, $0.isUnread) })
        XCTAssertEqual(unread[try fresh.requireID()], true)
        XCTAssertEqual(unread[try old.requireID()], false)
        XCTAssertEqual(unread[try mine.requireID()], false)

        let count = try await PostUnread.count(viewer: try alice.requireID(), groupID: groupID, on: db)
        XCTAssertEqual(count, 1)
        // Hiding the unread post takes it out of the count.
        try await fixtures.hide(post: fresh, by: alice)
        let afterHide = try await PostUnread.count(
            viewer: try alice.requireID(), groupID: groupID, on: db)
        XCTAssertEqual(afterHide, 0)
    }

    // MARK: - Delete

    func testDeletePermissions() async throws {
        let admin = try await fixtures.user()
        let bob = try await fixtures.user()
        let carol = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [bob, carol])
        let bobPost = try await fixtures.post(by: bob, in: group)
        _ = try await fixtures.media(uploadedBy: bob, in: group, post: bobPost)

        try assertError(
            try await send(.DELETE, "posts/\(try bobPost.requireID())", as: carol), 403,
            .forbidden)
        assertStatus(
            try await send(.DELETE, "posts/\(try bobPost.requireID())", as: bob), .noContent)
        let mediaLeft = try await Media.query(on: db).count()
        XCTAssertEqual(mediaLeft, 0, "photos go with the post")
        let queued = try await MediaFileDeletion.query(on: db).count()
        XCTAssertEqual(queued, 1, "the trigger queues the file")
        try assertError(
            try await send(.DELETE, "posts/\(try bobPost.requireID())", as: bob), 404, .notFound)

        let carolPost = try await fixtures.post(by: carol, in: group)
        assertStatus(
            try await send(.DELETE, "posts/\(try carolPost.requireID())", as: admin), .noContent)

        // While a vote is open nobody is admin; authors still delete their own.
        let another = try await fixtures.post(by: carol, in: group)
        try await setStatus(.voting, of: group)
        try assertError(
            try await send(.DELETE, "posts/\(try another.requireID())", as: admin), 409,
            .adminVoteInProgress)
        try await setStatus(.pendingDeletion, of: group)
        assertStatus(
            try await send(.DELETE, "posts/\(try another.requireID())", as: carol), .noContent)
    }

    // MARK: - Extend

    func testExtendBookReportsIdempotently() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let created = try decode(
            PostResponse.self,
            from: try await createPost(PostRequests.bookReport(), in: group, as: alice))

        let clientID = UUID()
        let path = "posts/\(created.id)/extend"
        let first = try await send(.POST, path, as: bob, json: ExtendPostRequest(clientId: clientID))
        XCTAssertEqual(first.status, .created, first.body.string)
        let extended = try decode(PostResponse.self, from: first)
        XCTAssertEqual(extended.extensionCount, 1)
        XCTAssertEqual(
            extended.expiresAt.timeIntervalSince(created.expiresAt), 7 * 86_400, accuracy: 0.001)

        let repeated = try await send(
            .POST, path, as: bob, json: ExtendPostRequest(clientId: clientID))
        XCTAssertEqual(repeated.status, .ok)
        XCTAssertEqual(try decode(PostResponse.self, from: repeated).extensionCount, 1)

        let again = try await send(.POST, path, as: alice, json: ExtendPostRequest(clientId: UUID()))
        XCTAssertEqual(try decode(PostResponse.self, from: again).extensionCount, 2)
        let rows = try await PostExtension.query(on: db).count()
        XCTAssertEqual(rows, 2)

        let testimony = try await fixtures.post(by: alice, in: group)
        try assertError(
            try await send(
                .POST, "posts/\(try testimony.requireID())/extend", as: bob,
                json: ExtendPostRequest(clientId: UUID())), 422, .extendNotAllowed)

        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await send(.POST, path, as: bob, json: ExtendPostRequest(clientId: UUID())), 409,
            .groupPendingDeletion)
    }
}
