import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// `PUT`/`DELETE /posts/:id/items/:index/answer` against Postgres.
final class PrayerItemAnswerTests: DatabaseTestCase {
    private let twoItems = [PrayerItem(text: "가족의 건강"), PrayerItem(text: "면접")]

    private func answerPath(_ post: PostResponse, _ index: String) -> String {
        "posts/\(post.id)/items/\(index)/answer"
    }

    private func prayer(by user: User, in group: Group, visibleDays: Int = 3) async throws
        -> PostResponse
    {
        try decode(
            PostResponse.self,
            from: try await createPost(
                PostRequests.prayer(items: twoItems, visibleDays: visibleDays), in: group,
                as: user))
    }

    private func answerCount() async throws -> Int {
        struct Row: Decodable { var n: Int }
        let row = try await sql.raw("SELECT count(*)::int AS n FROM prayer_item_answers")
            .first(decoding: Row.self)
        return row?.n ?? 0
    }

    private func answeredPushes() async throws -> [PushOutboxEntry] {
        try await PushOutboxEntry.query(on: db).all().filter { $0.kind == .prayerAnswered }
    }

    func testOnlyTheAuthorMarksAndUndoesAndTheExpiryNeverShrinks() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: alice, members: [bob])
        let created = try await prayer(by: alice, in: group)

        try assertError(try await sendV1(.PUT, answerPath(created, "0"), as: bob), 403, .forbidden)

        let first = try await sendV1(.PUT, answerPath(created, "0"), as: alice)
        assertStatus(first, .ok)
        let marked = try decode(PostResponse.self, from: first)
        let answeredAt = try XCTUnwrap(marked.items?[0].answeredAt)
        XCTAssertNil(marked.items?[1].answeredAt)
        // 3 visible days become at least 7 from the mark.
        XCTAssertEqual(
            marked.expiresAt.timeIntervalSince(answeredAt), 7 * 86_400, accuracy: 0.002)
        XCTAssertGreaterThan(marked.expiresAt, created.expiresAt)

        // Repeating changes nothing.
        let again = try decode(
            PostResponse.self, from: try await sendV1(.PUT, answerPath(created, "0"), as: alice))
        XCTAssertEqual(again.items?[0].answeredAt, answeredAt)
        XCTAssertEqual(again.expiresAt, marked.expiresAt)
        let count = try await answerCount()
        XCTAssertEqual(count, 1)

        // Members see it.
        let seen = try decode(
            PostResponse.self, from: try await sendV1(.GET, "posts/\(created.id)", as: bob))
        XCTAssertEqual(seen.items?[0].answeredAt, answeredAt)
        XCTAssertFalse(seen.isMine)

        try assertError(
            try await sendV1(.DELETE, answerPath(created, "0"), as: bob), 403, .forbidden)
        let undone = try decode(
            PostResponse.self,
            from: try await sendV1(.DELETE, answerPath(created, "0"), as: alice))
        XCTAssertNil(undone.items?[0].answeredAt)
        XCTAssertEqual(undone.expiresAt, marked.expiresAt, "undo never shortens")
        assertStatus(try await sendV1(.DELETE, answerPath(created, "0"), as: alice), .ok)
    }

    func testALongerExpiryIsKept() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let created = try await prayer(by: alice, in: group, visibleDays: 30)
        let marked = try decode(
            PostResponse.self, from: try await sendV1(.PUT, answerPath(created, "1"), as: alice))
        XCTAssertNotNil(marked.items?[1].answeredAt)
        XCTAssertEqual(marked.expiresAt, created.expiresAt)
    }

    func testIndexKindVisibilityAndGroupState() async throws {
        let alice = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let created = try await prayer(by: alice, in: group)

        for index in ["2", "-1", "x"] {
            try assertError(
                try await sendV1(.PUT, answerPath(created, index), as: alice), 422,
                .validationFailed)
        }
        let testimony = try await fixtures.post(by: alice, in: group)
        try assertError(
            try await sendV1(.PUT, "posts/\(try testimony.requireID())/items/0/answer", as: alice),
            422, .validationFailed)
        try assertError(
            try await sendV1(.PUT, answerPath(created, "0"), as: outsider), 404, .notFound)

        let expired = try await fixtures.post(
            by: alice, in: group, kind: .prayer, expiresAt: Date().addingTimeInterval(-60),
            items: twoItems)
        try assertError(
            try await sendV1(.PUT, "posts/\(try expired.requireID())/items/0/answer", as: alice),
            404, .notFound)

        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await sendV1(.PUT, answerPath(created, "0"), as: alice), 409,
            .groupPendingDeletion)
        try assertError(
            try await sendV1(.DELETE, answerPath(created, "0"), as: alice), 409,
            .groupPendingDeletion)
        let count = try await answerCount()
        XCTAssertEqual(count, 0)
    }

    func testOnePushPerPostPerTenMinutes() async throws {
        let author = try await fixtures.user("작성자")
        let plain = try await fixtures.user("멤버")
        let muted = try await fixtures.user("알림 끔")
        let group = try await fixtures.group("수요 기도모임", admin: author, members: [plain, muted])
        let mutedMembership = try await ContentVisibility.requireMembership(
            of: try muted.requireID(), in: try group.requireID(), on: db)
        mutedMembership.newPostPushEnabled = false
        try await mutedMembership.save(on: db)
        let created = try await prayer(by: author, in: group)

        assertStatus(try await sendV1(.PUT, answerPath(created, "0"), as: author), .ok)
        let pushes = try await answeredPushes()
        XCTAssertEqual(pushes.map { $0.$recipient.id }, [try plain.requireID()])
        let payload = try XCTUnwrap(pushes.first?.payload)
        XCTAssertEqual(payload.pilgrim.postId, created.id)
        XCTAssertEqual(payload.aps.alert.locKey, PushLocKey.prayerAnswered)
        XCTAssertEqual(payload.aps.alert.locArgs, ["작성자"])
        let json = String(decoding: try PilgrimJSON.encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("가족의 건강"))

        // Another item, or undo and mark again, within ten minutes: no second push.
        assertStatus(try await sendV1(.PUT, answerPath(created, "1"), as: author), .ok)
        assertStatus(try await sendV1(.DELETE, answerPath(created, "0"), as: author), .ok)
        assertStatus(try await sendV1(.PUT, answerPath(created, "0"), as: author), .ok)
        let quiet = try await answeredPushes()
        XCTAssertEqual(quiet.count, 1)

        // Ten minutes later a new mark notifies again.
        try await sql.raw(
            """
            UPDATE push_outbox SET created_at = created_at - interval '11 minutes'
            WHERE kind = 'prayerAnswered'
            """
        ).run()
        assertStatus(try await sendV1(.DELETE, answerPath(created, "1"), as: author), .ok)
        assertStatus(try await sendV1(.PUT, answerPath(created, "1"), as: author), .ok)
        let later = try await answeredPushes()
        XCTAssertEqual(later.count, 2)
    }

    func testAnswersGoWithThePost() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let created = try await prayer(by: alice, in: group)
        assertStatus(try await sendV1(.PUT, answerPath(created, "0"), as: alice), .ok)
        assertStatus(try await sendV1(.DELETE, "posts/\(created.id)", as: alice), .noContent)
        let count = try await answerCount()
        XCTAssertEqual(count, 0)
    }
}
