import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import XCTest

@testable import PilgrimServerCore

/// The migrations against real Postgres: every table, the constraints later tasks rely on, the
/// cascades and the media file trigger.
final class SchemaTests: DatabaseTestCase {
    private struct NameRow: Decodable {
        var name: String
    }

    func testEveryTableExists() async throws {
        let rows = try await sql.raw(
            """
            SELECT table_name AS name FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name <> '_fluent_migrations'
            """
        ).all(decoding: NameRow.self)
        XCTAssertEqual(Set(rows.map(\.name)), Set(PilgrimMigrations.tables))
    }

    func testModelsRoundTripEveryColumnType() async throws {
        let admin = try await fixtures.user("관리자")
        let member = try await fixtures.user("멤버")
        let group = try await fixtures.group(admin: admin, members: [member])
        let items = [PrayerItem(text: "기도", topic: "health", who: "엄마"), PrayerItem(text: "둘째")]
        let post = try await fixtures.post(by: admin, in: group, kind: .prayer, items: items)
        post.deadlineDate = LocalDate("2026-11-20")
        post.visibleDays = nil
        try await post.save(on: db)

        let reloaded = try await unwrapAsync(try await Post.find(post.id, on: db))
        XCTAssertEqual(reloaded.prayerItems, items)
        XCTAssertEqual(reloaded.deadlineDate, LocalDate("2026-11-20"))
        XCTAssertEqual(reloaded.kind, .prayer)

        // items is a single jsonb array, not jsonb[].
        struct TypeRow: Decodable {
            var type: String
            var length: Int
        }
        let typeRow = try await sql.raw(
            """
            SELECT jsonb_typeof(items) AS type, jsonb_array_length(items) AS length
            FROM posts WHERE id = \(bind: post.id!)
            """
        ).first(decoding: TypeRow.self)
        XCTAssertEqual(typeRow?.type, "array")
        XCTAssertEqual(typeRow?.length, 2)

        // uuid[] columns.
        let vote = AdminVote(
            groupID: try group.requireID(), round: 1,
            candidateIDs: [try admin.requireID(), try member.requireID()],
            eligibleIDs: [try member.requireID()], startedAt: Date(),
            endsAt: Date().addingTimeInterval(3 * 86_400))
        try await vote.create(on: db)
        let reloadedVote = try await unwrapAsync(try await AdminVote.find(vote.id, on: db))
        XCTAssertEqual(reloadedVote.candidateIDs, vote.candidateIDs)
        XCTAssertEqual(reloadedVote.status, .open)

        // jsonb payload and snapshot, bytea, enums.
        let payload = PushPayload.newPost(
            groupID: try group.requireID(), postID: try post.requireID(), kind: .prayer,
            groupName: group.name, authorName: "관리자")
        let entry = PushOutboxEntry(recipientID: try member.requireID(), payload: payload)
        try await entry.create(on: db)
        let reloadedEntry = try await unwrapAsync(
            try await PushOutboxEntry.find(entry.id, on: db))
        XCTAssertEqual(reloadedEntry.payload, payload)
        XCTAssertEqual(reloadedEntry.kind, .newPost)

        let snapshot = ReportSnapshot(
            authorId: try admin.requireID(), authorName: "관리자", title: nil, body: "본문",
            items: items, book: nil, mediaIds: [],
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let report = Report(
            reporterID: try member.requireID(), groupID: try group.requireID(), targetType: .post,
            targetID: try post.requireID(), targetUserID: try admin.requireID(), reason: .spam,
            note: nil, snapshot: snapshot, clientID: UUID())
        try await report.create(on: db)
        let reloadedReport = try await unwrapAsync(try await Report.find(report.id, on: db))
        XCTAssertEqual(reloadedReport.snapshot, snapshot)
        XCTAssertEqual(reloadedReport.status, .open)

        let device = Device(
            userID: try member.requireID(), installationID: UUID(), apnsToken: "ab12",
            apnsEnvironment: .sandbox, bundleID: BundleIDs.debug, platform: .ios)
        try await device.create(on: db)
        let token = AppleToken(
            userID: try member.requireID(), clientID: BundleIDs.debug,
            ciphertext: Data([1, 2, 3, 4]))
        try await token.create(on: db)
        let reloadedToken = try await unwrapAsync(try await AppleToken.find(token.id, on: db))
        XCTAssertEqual(reloadedToken.refreshTokenCiphertext, Data([1, 2, 3, 4]))

        let reloadedUser = try await unwrapAsync(try await User.find(admin.id, on: db))
        XCTAssertEqual(reloadedUser.dailyReportTime, LocalTime("22:00"))
        XCTAssertNotNil(reloadedUser.createdAt)
    }

    func testDeletingMediaQueuesItsFile() async throws {
        let user = try await fixtures.user()
        let group = try await fixtures.group(admin: user)
        let post = try await fixtures.post(by: user, in: group)
        let photos = [
            try await fixtures.media(uploadedBy: user, in: group, post: post),
            try await fixtures.media(uploadedBy: user, in: group, post: post),
        ]
        let unrelated = try await fixtures.media(uploadedBy: user, in: group)

        // Deleting the post cascades to its media rows; the trigger queues both files.
        try await post.delete(on: db)
        let queued = try await MediaFileDeletion.query(on: db).all().map(\.filePath)
        XCTAssertEqual(Set(queued), Set(photos.map(\.filePath)))
        let remaining = try await Media.query(on: db).all().map(\.id)
        XCTAssertEqual(remaining, [unrelated.id])
    }

    func testDeletingAUserCascadesAndQueuesFiles() async throws {
        let admin = try await fixtures.user("관리자")
        let member = try await fixtures.user("멤버")
        let group = try await fixtures.group(admin: admin, members: [member])
        let post = try await fixtures.post(by: member, in: group)
        let photo = try await fixtures.media(uploadedBy: member, in: group, post: post)
        let profile = try await fixtures.media(uploadedBy: member, in: nil, purpose: .profile)
        member.$profileMedia.id = profile.id
        try await member.save(on: db)
        try await Comment(
            postID: try post.requireID(), authorID: try admin.requireID(), body: "아멘",
            clientID: UUID()
        ).create(on: db)

        try await member.delete(on: db)

        let posts = try await Post.query(on: db).count()
        let comments = try await Comment.query(on: db).count()
        let memberships = try await Membership.query(on: db).count()
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(comments, 0)
        XCTAssertEqual(memberships, 1)
        let queued = try await MediaFileDeletion.query(on: db).all().map(\.filePath)
        XCTAssertEqual(Set(queued), [photo.filePath, profile.filePath])
        // The group survives; deleting the admin only clears admin_id.
        try await admin.delete(on: db)
        let reloadedGroup = try await unwrapAsync(try await Group.find(group.id, on: db))
        XCTAssertNil(reloadedGroup.$admin.id)
        XCTAssertNil(reloadedGroup.$createdBy.id)
    }

    func testReactionConstraints() async throws {
        let user = try await fixtures.user()
        let group = try await fixtures.group(admin: user)
        let post = try await fixtures.post(by: user, in: group)
        let postID = try post.requireID()
        let userID = try user.requireID()

        try await Reaction(postID: postID, userID: userID, key: .emoji("🙏")).create(on: db)
        do {
            try await Reaction(postID: postID, userID: userID, key: .emoji("🙏")).create(on: db)
            XCTFail("duplicate emoji reaction was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isUniqueViolation(error), "\(String(reflecting: error))")
        }
        try await Reaction(postID: postID, userID: userID, key: .emoji("❤️")).create(on: db)

        do {
            try await sql.raw(
                """
                INSERT INTO reactions (id, post_id, user_id, emoji, sticker_id)
                VALUES (\(bind: UUID()), \(bind: postID), \(bind: userID), NULL, NULL)
                """
            ).run()
            XCTFail("reaction without emoji or sticker was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isCheckViolation(error), "\(String(reflecting: error))")
        }
    }

    func testInviteUseCountCannotPassMaxUses() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let invite = Invite(
            groupID: try group.requireID(), code: "ABCDEFGHJKMN", createdByID: admin.id,
            maxUses: 1, expiresAt: Date().addingTimeInterval(3 * 86_400), clientID: UUID())
        try await invite.create(on: db)
        try await sql.raw("UPDATE invites SET use_count = 1 WHERE id = \(bind: invite.id!)").run()
        do {
            try await sql.raw("UPDATE invites SET use_count = 2 WHERE id = \(bind: invite.id!)")
                .run()
            XCTFail("use_count above max_uses was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isCheckViolation(error))
        }
    }

    func testOnlyOneOpenVotePerGroupAndHideShapes() async throws {
        let admin = try await fixtures.user()
        let other = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [other])
        func openVote() -> AdminVote {
            AdminVote(
                groupID: group.id!, round: 1, candidateIDs: [other.id!], eligibleIDs: [other.id!],
                startedAt: Date(), endsAt: Date().addingTimeInterval(60))
        }
        try await openVote().create(on: db)
        do {
            try await openVote().create(on: db)
            XCTFail("second open vote was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isUniqueViolation(error))
        }

        try await fixtures.hide(user: other, by: admin)
        do {
            try await fixtures.hide(user: other, by: admin)
            XCTFail("duplicate person hide was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isUniqueViolation(error))
        }
        do {
            try await fixtures.block(admin, admin)
            XCTFail("self block was accepted")
        } catch {
            XCTAssertTrue(Idempotency.isCheckViolation(error))
        }
    }

    func testRevertDropsEverything() async throws {
        try await app.autoRevert()
        let rows = try await sql.raw(
            """
            SELECT table_name AS name FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name <> '_fluent_migrations'
            """
        ).all(decoding: NameRow.self)
        XCTAssertEqual(rows.map(\.name), [])
        try await app.autoMigrate()
    }
}

/// `XCTUnwrap` for an awaited optional.
func unwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?, file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
