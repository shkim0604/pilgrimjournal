import Fluent
import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

final class ContentVisibilityTests: DatabaseTestCase {
    private func visibleIDs(to viewer: User, now: Date = Date()) async throws -> Set<UUID> {
        Set(
            try await Post.query(on: db).visible(to: try viewer.requireID(), now: now).all()
                .compactMap(\.id))
    }

    func testExpiryMembershipHidesAndBlocks() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let carol = try await fixtures.user("캐롤")
        let outsider = try await fixtures.user("외부인")
        let group = try await fixtures.group(admin: alice, members: [bob, carol])

        let alicePost = try await fixtures.post(by: alice, in: group)
        let bobPost = try await fixtures.post(by: bob, in: group)
        let carolPost = try await fixtures.post(by: carol, in: group)
        let expired = try await fixtures.post(
            by: alice, in: group, expiresAt: Date().addingTimeInterval(-1))

        let all: Set = [alicePost.id!, bobPost.id!, carolPost.id!]
        let aliceSees = try await visibleIDs(to: alice)
        XCTAssertEqual(aliceSees, all, "expired posts are never visible")
        let outsiderSees = try await visibleIDs(to: outsider)
        XCTAssertEqual(outsiderSees, [], "non-members see nothing")

        // Bob hides one post of Carol's and Alice as a person.
        try await fixtures.hide(post: carolPost, by: bob)
        try await fixtures.hide(user: alice, by: bob)
        let bobSees = try await visibleIDs(to: bob)
        XCTAssertEqual(bobSees, [bobPost.id!])
        // Hides apply only to the viewer who made them.
        let carolSees = try await visibleIDs(to: carol)
        XCTAssertEqual(carolSees, all)

        // Carol blocks Alice: neither sees the other's posts.
        try await fixtures.block(carol, alice)
        let carolAfterBlock = try await visibleIDs(to: carol)
        XCTAssertEqual(carolAfterBlock, [bobPost.id!, carolPost.id!])
        let aliceAfterBlock = try await visibleIDs(to: alice)
        XCTAssertEqual(aliceAfterBlock, [alicePost.id!, bobPost.id!])

        // Single-post lookup uses the same rule; a later clock hides everything.
        let found = try await ContentVisibility.visiblePost(
            try bobPost.requireID(), viewer: try carol.requireID(), on: db)
        XCTAssertNotNil(found)
        let gone = try await ContentVisibility.visiblePost(
            try expired.requireID(), viewer: try alice.requireID(), on: db)
        XCTAssertNil(gone)
        let later = try await visibleIDs(to: alice, now: Date().addingTimeInterval(8 * 86_400))
        XCTAssertEqual(later, [])
    }

    func testCommentsAndReactionsFollowAuthorVisibility() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let carol = try await fixtures.user("캐롤")
        let group = try await fixtures.group(admin: alice, members: [bob, carol])
        let post = try await fixtures.post(by: alice, in: group)
        for author in [alice, bob, carol] {
            try await Comment(
                postID: post.id!, authorID: author.id!, body: "댓글", clientID: UUID()
            ).create(on: db)
            try await Reaction(postID: post.id!, userID: author.id!, key: .emoji("🙏"))
                .create(on: db)
        }
        try await fixtures.block(bob, carol)
        try await fixtures.hide(user: alice, by: bob)

        let comments = try await Comment.query(on: db).filter(\.$post.$id == post.id!)
            .visibleAuthors(to: bob.id!).all().map { $0.$author.id }
        XCTAssertEqual(comments, [bob.id!])
        let reactions = try await Reaction.query(on: db).filter(\.$post.$id == post.id!)
            .visibleAuthors(to: carol.id!).all().map { $0.$user.id }
        XCTAssertEqual(Set(reactions), [alice.id!, carol.id!])
    }

    func testMembershipHelpers() async throws {
        let alice = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let membership = try await ContentVisibility.requireMembership(
            of: alice.id!, in: group.id!, on: db)
        XCTAssertEqual(membership.$user.id, alice.id)
        do {
            _ = try await ContentVisibility.requireMembership(
                of: outsider.id!, in: group.id!, on: db)
            XCTFail("outsider has a membership")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .notFound)
        }
        let blockedBefore = try await ContentVisibility.isBlockedEitherWay(
            alice.id!, outsider.id!, on: db)
        XCTAssertFalse(blockedBefore)
        try await fixtures.block(outsider, alice)
        let blockedAfter = try await ContentVisibility.isBlockedEitherWay(
            alice.id!, outsider.id!, on: db)
        XCTAssertTrue(blockedAfter)
    }
}

final class PushOutboxTests: DatabaseTestCase {
    func testNewPostRecipientsSkipAuthorMutedBlockedAndHidden() async throws {
        let author = try await fixtures.user("민지")
        let plain = try await fixtures.user("준호")
        let muted = try await fixtures.user("음소거")
        let blocker = try await fixtures.user("차단한사람")
        let blockedByAuthor = try await fixtures.user("차단된사람")
        let hider = try await fixtures.user("숨긴사람")
        let group = try await fixtures.group(
            "수요 기도모임", admin: author,
            members: [plain, muted, blocker, blockedByAuthor, hider])
        let mutedMembership = try await ContentVisibility.requireMembership(
            of: muted.id!, in: group.id!, on: db)
        mutedMembership.newPostPushEnabled = false
        try await mutedMembership.save(on: db)
        try await fixtures.block(blocker, author)
        try await fixtures.block(author, blockedByAuthor)
        try await fixtures.hide(user: author, by: hider)

        let post = try await fixtures.post(
            by: author, in: group, kind: .prayer, body: "비밀스러운 기도 내용",
            items: [PrayerItem(text: "어머니 건강")])
        let count = try await db.transaction { tx in
            try await PushOutbox.enqueue(on: tx, post: post)
        }
        XCTAssertEqual(count, 1)

        let entries = try await PushOutboxEntry.query(on: db).all()
        XCTAssertEqual(entries.map { $0.$recipient.id }, [plain.id!])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.kind, .newPost)
        XCTAssertEqual(
            entry.payload,
            PushPayload.newPost(
                groupID: group.id!, postID: post.id!, kind: .prayer, groupName: "수요 기도모임",
                authorName: "민지"))
        // Nothing from the post's content reaches the payload.
        let json = String(decoding: try PilgrimJSON.encode(entry.payload), as: UTF8.self)
        XCTAssertFalse(json.contains("비밀"))
        XCTAssertFalse(json.contains("어머니"))
    }

    func testGroupEventGoesToEveryMember() async throws {
        let admin = try await fixtures.user()
        let a = try await fixtures.user()
        let b = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [a, b])
        let count = try await PushOutbox.enqueue(
            on: db, groupEvent: .voteStarted, groupID: group.id!, excluding: [admin.id!])
        XCTAssertEqual(count, 2)
        let kinds = try await PushOutboxEntry.query(on: db).all().map(\.kind)
        XCTAssertEqual(kinds, [.voteStarted, .voteStarted])
    }
}

final class IdempotencyTests: DatabaseTestCase {
    func testSecondRequestReturnsTheFirstResource() async throws {
        let author = try await fixtures.user()
        let group = try await fixtures.group(admin: author)
        let clientID = UUID()
        let authorID = try author.requireID()
        let groupID = try group.requireID()
        let database = db

        @Sendable func attempt(body: String) async throws -> Idempotency.Outcome<Post> {
            try await Idempotency.findOrCreate(
                on: database,
                existing: { db in
                    try await Post.query(on: db)
                        .filter(\.$author.$id == authorID)
                        .filter(\.$clientID == clientID)
                        .first()
                },
                create: { db in
                    let post = Post(
                        groupID: groupID, authorID: authorID, kind: .testimony,
                        timeZone: "Asia/Seoul", expiresAt: Date().addingTimeInterval(60),
                        clientID: clientID)
                    post.body = body
                    try await post.create(on: db)
                    return post
                })
        }

        let first = try await attempt(body: "처음")
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.status, .created)
        let second = try await attempt(body: "다른 내용")
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(second.value.id, first.value.id)
        XCTAssertEqual(second.value.body, "처음")
        let count = try await Post.query(on: db).count()
        XCTAssertEqual(count, 1)
    }
}
