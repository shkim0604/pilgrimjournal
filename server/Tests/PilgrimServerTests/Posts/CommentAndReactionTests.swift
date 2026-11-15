import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// `posts/:id/comments`, `comments/:id` and `posts/:id/reactions` against Postgres.
final class CommentAndReactionTests: DatabaseTestCase {
    private func comment(
        _ body: String, on post: Post, as user: User, clientId: UUID = UUID(),
        media: [UUID] = [], sticker: UUID? = nil
    ) async throws -> XCTHTTPResponse {
        try await send(
            .POST, "posts/\(try post.requireID())/comments", as: user,
            json: CreateCommentRequest(
                clientId: clientId, body: body, mediaIds: media, stickerId: sticker))
    }

    // MARK: - Comments

    func testCreateListAndRepeatComments() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: alice, members: [bob])
        let post = try await fixtures.post(by: alice, in: group)

        let clientID = UUID()
        let first = try await comment(" 아멘 ", on: post, as: bob, clientId: clientID)
        assertStatus(first, .created)
        let created = try decode(CommentResponse.self, from: first)
        XCTAssertEqual(created.body, "아멘")
        XCTAssertTrue(created.isMine)
        let repeated = try await comment("다른 말", on: post, as: bob, clientId: clientID)
        assertStatus(repeated, .ok)
        XCTAssertEqual(try decode(CommentResponse.self, from: repeated).id, created.id)

        for index in 0..<4 {
            assertStatus(try await comment("댓글 \(index)", on: post, as: alice), .created)
        }
        var bodies: [String] = []
        var cursor: String?
        repeat {
            var path = "posts/\(try post.requireID())/comments?limit=2"
            if let cursor { path += "&cursor=\(cursor)" }
            let page = try decode(
                APIPage<CommentResponse>.self, from: try await send(.GET, path, as: bob))
            bodies += page.items.map(\.body)
            cursor = page.nextCursor
        } while cursor != nil && bodies.count < 20
        XCTAssertEqual(bodies, ["아멘", "댓글 0", "댓글 1", "댓글 2", "댓글 3"], "oldest first")

        let detail = try decode(
            PostResponse.self, from: try await send(.GET, "posts/\(try post.requireID())", as: bob))
        XCTAssertEqual(detail.commentCount, 5)
    }

    func testCommentRules() async throws {
        let alice = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let other = try await fixtures.group(admin: alice)
        let post = try await fixtures.post(by: alice, in: group)

        try assertError(try await comment("  ", on: post, as: alice), 422, .validationFailed)
        try assertError(
            try await comment(String(repeating: "가", count: 501), on: post, as: alice), 422,
            .limitExceeded)
        try assertError(try await comment("안녕", on: post, as: outsider), 404, .notFound)
        let expired = try await fixtures.post(
            by: alice, in: group, expiresAt: Date().addingTimeInterval(-1))
        try assertError(try await comment("늦음", on: expired, as: alice), 404, .notFound)

        // Stickers: only the post's group's, and a photo attaches to the comment.
        let foreign = try await makeSticker(by: alice, in: other)
        try assertError(
            try await comment("", on: post, as: alice, sticker: try foreign.requireID()), 404,
            .notFound)
        let sticker = try await makeSticker(by: alice, in: group)
        let photo = try await fixtures.media(uploadedBy: alice, in: group, purpose: .comment)
        let response = try await comment(
            "", on: post, as: alice, media: [try photo.requireID()],
            sticker: try sticker.requireID())
        assertStatus(response, .created)
        let created = try decode(CommentResponse.self, from: response)
        XCTAssertEqual(created.sticker?.id, try sticker.requireID())
        XCTAssertEqual(created.media.map(\.id), [try photo.requireID()])
        XCTAssertFalse(created.stickerRemoved)

        // Deleting the sticker leaves the comment, shown as a removed sticker.
        try await sticker.delete(on: db)
        let page = try decode(
            APIPage<CommentResponse>.self,
            from: try await send(.GET, "posts/\(try post.requireID())/comments", as: alice))
        XCTAssertEqual(page.items.first?.sticker, nil)
        XCTAssertEqual(page.items.first?.stickerRemoved, true)

        try await setStatus(.pendingDeletion, of: group)
        try assertError(try await comment("안녕", on: post, as: alice), 409, .groupPendingDeletion)
    }

    func testBlockedAndHiddenCommentersDisappear() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let carol = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob, carol])
        let post = try await fixtures.post(by: alice, in: group)
        assertStatus(try await comment("밥", on: post, as: bob), .created)
        assertStatus(try await comment("캐롤", on: post, as: carol), .created)

        try await fixtures.block(alice, bob)
        try await fixtures.hide(user: carol, by: alice)
        let page = try decode(
            APIPage<CommentResponse>.self,
            from: try await send(.GET, "posts/\(try post.requireID())/comments", as: alice))
        XCTAssertEqual(page.items, [])
        let detail = try decode(
            PostResponse.self,
            from: try await send(.GET, "posts/\(try post.requireID())", as: alice))
        XCTAssertEqual(detail.commentCount, 0)
        // Carol, who blocked nobody, still sees both.
        let carolPage = try decode(
            APIPage<CommentResponse>.self,
            from: try await send(.GET, "posts/\(try post.requireID())/comments", as: carol))
        XCTAssertEqual(carolPage.items.count, 2)
    }

    func testDeleteCommentPermissions() async throws {
        let admin = try await fixtures.user()
        let bob = try await fixtures.user()
        let carol = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [bob, carol])
        let post = try await fixtures.post(by: carol, in: group)
        let bobs = try decode(
            CommentResponse.self, from: try await comment("밥", on: post, as: bob))
        let carols = try decode(
            CommentResponse.self, from: try await comment("캐롤", on: post, as: carol))

        try assertError(
            try await send(.DELETE, "comments/\(bobs.id)", as: carol), 403, .forbidden)
        assertStatus(try await send(.DELETE, "comments/\(bobs.id)", as: bob), .noContent)
        try assertError(try await send(.DELETE, "comments/\(bobs.id)", as: bob), 404, .notFound)

        try await setStatus(.voting, of: group)
        try assertError(
            try await send(.DELETE, "comments/\(carols.id)", as: admin), 409,
            .adminVoteInProgress)
        try await setStatus(.active, of: group)
        group.$admin.id = try admin.requireID()
        try await group.save(on: db)
        assertStatus(try await send(.DELETE, "comments/\(carols.id)", as: admin), .noContent)
    }

    // MARK: - Reactions

    private func react(_ key: ReactionKey, on post: Post, as user: User) async throws
        -> XCTHTTPResponse
    {
        try await send(
            .PUT, "posts/\(try post.requireID())/reactions", as: user,
            json: ReactionRequest(key: key))
    }

    func testReactionsAreIdempotentAndCounted() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let post = try await fixtures.post(by: alice, in: group)
        let sticker = try await makeSticker(by: bob, in: group)

        assertStatus(try await react(.emoji("🙏"), on: post, as: alice), .ok)
        assertStatus(try await react(.emoji("🙏"), on: post, as: alice), .ok)
        let summaries = try decode(
            [ReactionSummary].self, from: try await react(.emoji("🙏"), on: post, as: bob))
        XCTAssertEqual(summaries, [ReactionSummary(key: .emoji("🙏"), count: 2, reactedByMe: true)])
        let withSticker = try decode(
            [ReactionSummary].self,
            from: try await react(.sticker(try sticker.requireID()), on: post, as: alice))
        XCTAssertEqual(
            withSticker,
            [
                ReactionSummary(key: .emoji("🙏"), count: 2, reactedByMe: true),
                ReactionSummary(key: .sticker(try sticker.requireID()), count: 1, reactedByMe: true),
            ])

        // Removing: by query, twice is fine.
        let path = "posts/\(try post.requireID())/reactions?emoji=%F0%9F%99%8F"
        let removed = try decode([ReactionSummary].self, from: try await send(.DELETE, path, as: bob))
        XCTAssertEqual(removed.first, ReactionSummary(key: .emoji("🙏"), count: 1, reactedByMe: false))
        assertStatus(try await send(.DELETE, path, as: bob), .ok)
        try assertError(
            try await send(.DELETE, "posts/\(try post.requireID())/reactions", as: bob), 400,
            .invalidRequest)

        // The post response carries the same summaries.
        let detail = try decode(
            PostResponse.self, from: try await send(.GET, "posts/\(try post.requireID())", as: alice))
        XCTAssertEqual(detail.reactions.count, 2)
    }

    func testReactionRules() async throws {
        let alice = try await fixtures.user()
        let bob = try await fixtures.user()
        let group = try await fixtures.group(admin: alice, members: [bob])
        let other = try await fixtures.group(admin: alice)
        let post = try await fixtures.post(by: alice, in: group)

        try assertError(try await react(.emoji("아멘"), on: post, as: bob), 422, .validationFailed)
        let foreign = try await makeSticker(by: alice, in: other)
        try assertError(
            try await react(.sticker(try foreign.requireID()), on: post, as: bob), 404, .notFound)

        let emoji = ["🙏", "❤️", "👍", "😊", "😭", "🔥", "✨", "🌱", "📖", "🕊️", "🎉"]
        for value in emoji.prefix(10) {
            assertStatus(try await react(.emoji(value), on: post, as: bob), .ok)
        }
        try assertError(try await react(.emoji(emoji[10]), on: post, as: bob), 422, .limitExceeded)
        // An existing one is still fine at the limit.
        assertStatus(try await react(.emoji("🙏"), on: post, as: bob), .ok)

        // Blocked people's reactions drop out of the counts.
        try await fixtures.block(alice, bob)
        let summaries = try decode(
            [ReactionSummary].self, from: try await react(.emoji("🙏"), on: post, as: alice))
        XCTAssertEqual(summaries, [ReactionSummary(key: .emoji("🙏"), count: 1, reactedByMe: true)])

        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await react(.emoji("👍"), on: post, as: alice), 409, .groupPendingDeletion)
    }
}
