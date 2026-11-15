import Fluent
import Foundation
import NIOConcurrencyHelpers
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Records webhook summaries instead of POSTing them.
final class RecordingReportNotifier: ReportNotifying {
    private let box = NIOLockedValueBox<[ReportWebhookSummary]>([])

    var summaries: [ReportWebhookSummary] { box.withLockedValue { $0 } }

    func reportFiled(_ summary: ReportWebhookSummary, app: Application) {
        box.withLockedValue { $0.append(summary) }
    }
}

/// Blocks, hides and reports (`/api/v1/me/blocks`, `me/hides`, `reports`) against Postgres.
final class ModerationTests: DatabaseTestCase {
    private var notifier: RecordingReportNotifier!

    override func prepareDatabase() async throws {
        try await super.prepareDatabase()
        notifier = RecordingReportNotifier()
        app.reportNotifier = notifier
    }

    private func id(_ user: User) throws -> UUID { try user.requireID() }

    // MARK: - Account gate

    func testSuspendedAndUnnamedUsersAreRefused() async throws {
        let suspended = try await fixtures.user("정지")
        suspended.suspendedAt = Date()
        try await suspended.update(on: db)
        try await app.test(.GET, "api/v1/me/blocks", headers: try headers(as: suspended)) {
            res async throws in
            XCTAssertEqual(res.status, .forbidden)
            XCTAssertEqual(try errorBody(res).code, .accountSuspended)
        }

        let unnamed = try await fixtures.user(nil)
        try await app.test(.GET, "api/v1/me/hides", headers: try headers(as: unnamed)) {
            res async throws in
            XCTAssertEqual(res.status, .forbidden)
            XCTAssertEqual(try errorBody(res).code, .signupRequired)
        }

        let ghost = User(appleSub: "dev:ghost", displayName: "유령", timeZone: "Asia/Seoul")
        ghost.id = UUID()
        try await app.test(.GET, "api/v1/me/blocks", headers: try headers(as: ghost)) {
            res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - Blocks

    func testBlockListUnblockAndIdempotency() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        try await fixtures.group(admin: alice, members: [bob])

        for _ in 0..<2 {
            try await app.test(
                .PUT, "api/v1/me/blocks/\(try id(bob))", headers: try headers(as: alice)
            ) {
                res async throws in
                XCTAssertEqual(res.status, .noContent)
            }
        }
        try await app.test(.GET, "api/v1/me/blocks", headers: try headers(as: alice)) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
            let users = try decode([UserSummary].self, from: res)
            XCTAssertEqual(users.map(\.id), [try id(bob)])
            XCTAssertEqual(users.first?.displayName, "밥")
        }
        // The blocked person never learns about it.
        try await app.test(.GET, "api/v1/me/blocks", headers: try headers(as: bob)) {
            res async throws in
            XCTAssertEqual(try decode([UserSummary].self, from: res), [])
        }
        // Only the blocker can unblock.
        try await app.test(
            .DELETE, "api/v1/me/blocks/\(try id(alice))", headers: try headers(as: bob)
        ) {
            res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        expectEqual(try await Block.query(on: db).count(), 1)

        try await app.test(
            .DELETE, "api/v1/me/blocks/\(try id(bob))", headers: try headers(as: alice)
        ) {
            res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        expectEqual(try await Block.query(on: db).count(), 0)
    }

    func testBlockingIsBidirectionalForVisibility() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: alice, members: [bob])
        try await fixtures.post(by: alice, in: group)
        try await fixtures.post(by: bob, in: group)

        try await ModerationService.block(try id(bob), by: try id(alice), on: db)

        let visibleToAlice = try await Post.query(on: db)
            .filter(.sql(ContentVisibility.visiblePost(viewer: try id(alice), now: Date())))
            .all()
        XCTAssertEqual(visibleToAlice.map(\.$author.id), [try id(alice)])
        let visibleToBob = try await Post.query(on: db)
            .filter(.sql(ContentVisibility.visiblePost(viewer: try id(bob), now: Date())))
            .all()
        XCTAssertEqual(visibleToBob.map(\.$author.id), [try id(bob)])
    }

    func testBlockNeedsASharedGroupAndAnotherUser() async throws {
        let alice = try await fixtures.user("앨리스")
        let stranger = try await fixtures.user("남")
        try await fixtures.group(admin: alice)
        try await fixtures.group(admin: stranger)

        try await app.test(
            .PUT, "api/v1/me/blocks/\(try id(stranger))", headers: try headers(as: alice)
        ) {
            res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.test(.PUT, "api/v1/me/blocks/\(UUID())", headers: try headers(as: alice)) {
            res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.test(
            .PUT, "api/v1/me/blocks/\(try id(alice))", headers: try headers(as: alice)
        ) {
            res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
            XCTAssertEqual(try errorBody(res).code, .cannotTargetSelf)
        }
    }

    // MARK: - Hides

    func testHidePostsAndPeople() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group("금요 모임", admin: alice, members: [bob])
        let post = try await fixtures.post(by: bob, in: group)
        post.title = "제목"
        try await post.update(on: db)
        let postID = try post.requireID()

        for path in ["posts/\(postID)", "users/\(try id(bob))"] {
            for _ in 0..<2 {
                try await app.test(.PUT, "api/v1/me/hides/\(path)", headers: try headers(as: alice))
                {
                    res async throws in
                    XCTAssertEqual(res.status, .noContent, path)
                }
            }
        }
        try await app.test(.GET, "api/v1/me/hides", headers: try headers(as: alice)) {
            res async throws in
            let hides = try decode(HidesResponse.self, from: res)
            XCTAssertEqual(hides.posts.map(\.postId), [postID])
            XCTAssertEqual(hides.posts.first?.groupName, "금요 모임")
            XCTAssertEqual(hides.posts.first?.title, "제목")
            XCTAssertEqual(hides.users.map(\.user.id), [try id(bob)])
        }

        for path in ["posts/\(postID)", "users/\(try id(bob))"] {
            try await app.test(.DELETE, "api/v1/me/hides/\(path)", headers: try headers(as: alice))
            {
                res async throws in
                XCTAssertEqual(res.status, .noContent, path)
            }
        }
        expectEqual(try await Hide.query(on: db).count(), 0)
    }

    func testHidePostRefusesOwnForeignAndExpiredPosts() async throws {
        let alice = try await fixtures.user("앨리스")
        let carol = try await fixtures.user("캐롤")
        let mine = try await fixtures.group(admin: alice)
        let other = try await fixtures.group(admin: carol)
        let own = try await fixtures.post(by: alice, in: mine)
        let foreign = try await fixtures.post(by: carol, in: other)
        try await fixtures.join(carol, mine)
        let expired = try await fixtures.post(
            by: carol, in: mine, expiresAt: Date().addingTimeInterval(-60))

        try await app.test(
            .PUT, "api/v1/me/hides/posts/\(try own.requireID())", headers: try headers(as: alice)
        ) {
            res async throws in
            XCTAssertEqual(try errorBody(res).code, .cannotTargetSelf)
        }
        for post in [foreign, expired] {
            try await app.test(
                .PUT, "api/v1/me/hides/posts/\(try post.requireID())",
                headers: try headers(as: alice)
            ) { res async throws in
                XCTAssertEqual(res.status, .notFound)
            }
        }
        try await app.test(
            .PUT, "api/v1/me/hides/users/\(try id(alice))", headers: try headers(as: alice)
        ) {
            res async throws in
            XCTAssertEqual(try errorBody(res).code, .cannotTargetSelf)
        }
    }

    // MARK: - Reports

    private func report(
        _ request: CreateReportRequest, as user: User,
        _ check: @escaping (XCTHTTPResponse) async throws -> Void
    ) async throws {
        try await app.test(
            .POST, "api/v1/reports", headers: try headers(as: user),
            beforeRequest: { req in try req.content.encode(request, as: .json) },
            afterResponse: check)
    }

    func testReportSnapshotsIdempotencyAndWebhook() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: alice, members: [bob])
        let post = try await fixtures.post(by: bob, in: group, body: "신고할 본문")
        let photo = try await fixtures.media(uploadedBy: bob, in: group, post: post)
        let request = CreateReportRequest(
            clientId: UUID(), targetType: .post, targetId: try post.requireID(),
            groupId: try group.requireID(), reason: .inappropriate, note: "  불쾌해요 ")

        var first: ReportReceipt?
        try await report(request, as: alice) { res in
            XCTAssertEqual(res.status, .created)
            first = try self.decode(ReportReceipt.self, from: res)
        }
        try await report(request, as: alice) { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(try self.decode(ReportReceipt.self, from: res).id, first?.id)
        }

        let rows = try await Report.query(on: db).all()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.$reporter.id, try id(alice))
        XCTAssertEqual(row.$targetUser.id, try id(bob))
        XCTAssertEqual(row.note, "불쾌해요")
        XCTAssertEqual(row.status, .open)
        XCTAssertEqual(row.snapshot.authorName, "밥")
        XCTAssertEqual(row.snapshot.body, "신고할 본문")
        XCTAssertEqual(row.snapshot.mediaIds, [try photo.requireID()])

        // One webhook call, only reason and type.
        XCTAssertEqual(
            notifier.summaries, [ReportWebhookSummary(reason: .inappropriate, targetType: .post)])
    }

    func testReportCommentStickerAndUserTargets() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let group = try await fixtures.group(admin: alice, members: [bob])
        let groupID = try group.requireID()
        let post = try await fixtures.post(by: alice, in: group)
        let comment = Comment(
            postID: try post.requireID(), authorID: try id(bob), body: "댓글", clientID: UUID())
        try await comment.create(on: db)
        let stickerMedia = try await fixtures.media(uploadedBy: bob, in: group, purpose: .sticker)
        let sticker = Sticker(
            groupID: groupID, createdByID: try id(bob), mediaID: try stickerMedia.requireID(),
            name: "웃음", clientID: UUID())
        try await sticker.create(on: db)

        let targets: [(ReportTargetType, UUID)] = [
            (.comment, try comment.requireID()), (.sticker, try sticker.requireID()),
            (.user, try id(bob)),
        ]
        for (type, targetID) in targets {
            let request = CreateReportRequest(
                clientId: UUID(), targetType: type, targetId: targetID, groupId: groupID,
                reason: .spam)
            try await report(request, as: alice) { res in
                XCTAssertEqual(res.status, .created, type.rawValue)
            }
        }
        let rows = try await Report.query(on: db).all()
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.$targetUser.id == bob.id })
        XCTAssertEqual(rows.first { $0.targetType == .comment }?.snapshot.body, "댓글")
        XCTAssertEqual(rows.first { $0.targetType == .sticker }?.snapshot.title, "웃음")
    }

    func testReportRefusals() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let carol = try await fixtures.user("캐롤")
        let group = try await fixtures.group(admin: alice, members: [bob])
        let groupID = try group.requireID()
        let own = try await fixtures.post(by: alice, in: group)
        let bobsPost = try await fixtures.post(by: bob, in: group)

        // Own content → 422.
        try await report(
            CreateReportRequest(
                clientId: UUID(), targetType: .post, targetId: try own.requireID(),
                groupId: groupID,
                reason: .spam), as: alice
        ) { res in
            XCTAssertEqual(try self.errorBody(res).code, .cannotTargetSelf)
        }
        // Not a member → 404.
        try await report(
            CreateReportRequest(
                clientId: UUID(), targetType: .post, targetId: try bobsPost.requireID(),
                groupId: groupID, reason: .spam), as: carol
        ) { res in
            XCTAssertEqual(res.status, .notFound)
        }
        // Target in another group → 404.
        let elsewhere = try await fixtures.group(admin: carol, members: [alice])
        try await report(
            CreateReportRequest(
                clientId: UUID(), targetType: .post, targetId: try bobsPost.requireID(),
                groupId: try elsewhere.requireID(), reason: .spam), as: alice
        ) { res in
            XCTAssertEqual(res.status, .notFound)
        }
        // Note too long → 422.
        try await report(
            CreateReportRequest(
                clientId: UUID(), targetType: .post, targetId: try bobsPost.requireID(),
                groupId: groupID, reason: .other,
                note: String(repeating: "가", count: APILimits.reportNoteMax + 1)), as: alice
        ) { res in
            XCTAssertEqual(try self.errorBody(res).code, .limitExceeded)
        }
        expectEqual(try await Report.query(on: db).count(), 0)
        XCTAssertEqual(notifier.summaries, [])
    }

    func testPurgeDeletesReportsOlderThan90Days() async throws {
        let alice = try await fixtures.user("앨리스")
        let snapshot = ReportSnapshot(
            authorId: nil, authorName: nil, mediaIds: [], capturedAt: Date())
        for _ in 0..<2 {
            try await Report(
                reporterID: try id(alice), groupID: nil, targetType: .user, targetID: UUID(),
                targetUserID: nil, reason: .spam, note: nil, snapshot: snapshot, clientID: UUID()
            ).create(on: db)
        }
        let old = Date().addingTimeInterval(-ModerationService.reportRetention - 60)
        let oldest = try unwrap(try await Report.query(on: db).first())
        try await sql.raw(
            "UPDATE reports SET created_at = \(bind: old) WHERE id = \(bind: try oldest.requireID())"
        ).run()

        expectEqual(try await ModerationService.purgeExpiredReportSnapshots(on: db), 1)
        expectEqual(try await Report.query(on: db).count(), 1)
    }
}

/// `/internal/admin/v1/*` against Postgres.
final class AdminRoutesTests: DatabaseTestCase {
    private func adminHeaders(actor: String = "운영자") -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(
            name: PilgrimHeader.adminToken, value: app.pilgrimConfig.adminAPIToken ?? "")
        headers.replaceOrAdd(name: PilgrimHeader.adminActor, value: actor)
        return headers
    }

    private struct Scene {
        var reporter: User
        var author: User
        var group: Group
        var post: Post
        var report: Report
    }

    private func scene() async throws -> Scene {
        let reporter = try await fixtures.user("신고자")
        let author = try await fixtures.user("작성자")
        let group = try await fixtures.group("모임", admin: reporter, members: [author])
        let post = try await fixtures.post(by: author, in: group, body: "문제 글")
        let outcome = try await ModerationService.fileReport(
            CreateReportRequest(
                clientId: UUID(), targetType: .post, targetId: try post.requireID(),
                groupId: try group.requireID(), reason: .harassment),
            by: try reporter.requireID(), on: db)
        return Scene(
            reporter: reporter, author: author, group: group, post: post, report: outcome.value)
    }

    func testListDetailAndResolve() async throws {
        let scene = try await scene()
        let reportID = try scene.report.requireID()

        try await app.test(.GET, "internal/admin/v1/reports?status=open", headers: adminHeaders()) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
            let page = try decode(PilgrimAPI.Page<AdminReport>.self, from: res)
            XCTAssertEqual(page.items.map(\.id), [reportID])
            XCTAssertNil(page.nextCursor)
            let item = try XCTUnwrap(page.items.first)
            XCTAssertEqual(item.groupName, "모임")
            XCTAssertEqual(item.reporter?.displayName, "신고자")
            XCTAssertEqual(item.targetUser?.displayName, "작성자")
            XCTAssertEqual(item.snapshot.body, "문제 글")
        }
        try await app.test(.GET, "internal/admin/v1/reports/\(reportID)", headers: adminHeaders()) {
            res async throws in
            let detail = try decode(AdminReportDetail.self, from: res)
            XCTAssertEqual(detail.liveTarget?.exists, true)
            XCTAssertEqual(detail.liveTarget?.post?.body, "문제 글")
        }
        try await app.test(
            .POST, "internal/admin/v1/reports/\(reportID)/resolve", headers: adminHeaders(),
            beforeRequest: { req in
                try req.content.encode(
                    ResolveReportRequest(resolution: .dismissed, note: "문제 없음"), as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let report = try decode(AdminReport.self, from: res)
            XCTAssertEqual(report.status, .dismissed)
            XCTAssertEqual(report.resolvedBy, "운영자")
            XCTAssertNotNil(report.resolvedAt)
        }
        try await app.test(.GET, "internal/admin/v1/reports?status=open", headers: adminHeaders()) {
            res async throws in
            XCTAssertEqual(try decode(PilgrimAPI.Page<AdminReport>.self, from: res).items, [])
        }
        let log = try await ModerationLogEntry.query(on: db).all()
        XCTAssertEqual(log.map(\.action), [.resolveReport])
        XCTAssertEqual(log.first?.note, "문제 없음")
        XCTAssertEqual(log.first?.reportID, reportID)
    }

    func testPaging() async throws {
        let scene = try await scene()
        for _ in 0..<2 {
            _ = try await ModerationService.fileReport(
                CreateReportRequest(
                    clientId: UUID(), targetType: .user, targetId: try scene.author.requireID(),
                    groupId: try scene.group.requireID(), reason: .spam),
                by: try scene.reporter.requireID(), on: db)
        }
        var seen: [UUID] = []
        var cursor: String?
        repeat {
            let path = "internal/admin/v1/reports?limit=2" + (cursor.map { "&cursor=\($0)" } ?? "")
            try await app.test(.GET, path, headers: adminHeaders()) { res async throws in
                let page = try decode(PilgrimAPI.Page<AdminReport>.self, from: res)
                seen += page.items.map(\.id)
                cursor = page.nextCursor
            }
        } while cursor != nil
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(Set(seen).count, 3)
    }

    func testDeletePostLogsAndLeavesTheReport() async throws {
        let scene = try await scene()
        let postID = try scene.post.requireID()
        let reportID = try scene.report.requireID()

        try await app.test(
            .DELETE, "internal/admin/v1/posts/\(postID)?reportId=\(reportID)",
            headers: adminHeaders()
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        expectNil(try await Post.find(postID, on: db))
        try await app.test(.DELETE, "internal/admin/v1/posts/\(postID)", headers: adminHeaders()) {
            res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
        try await app.test(.GET, "internal/admin/v1/reports/\(reportID)", headers: adminHeaders()) {
            res async throws in
            let detail = try decode(AdminReportDetail.self, from: res)
            XCTAssertEqual(detail.liveTarget?.exists, false)
            XCTAssertEqual(detail.report.snapshot.body, "문제 글")
        }
        let log = try unwrap(try await ModerationLogEntry.query(on: db).first())
        XCTAssertEqual(log.action, .deletePost)
        XCTAssertEqual(log.targetID, postID)
        XCTAssertEqual(log.reportID, reportID)
        XCTAssertEqual(log.actor, "운영자")
    }

    func testDeleteCommentAndSticker() async throws {
        let scene = try await scene()
        let comment = Comment(
            postID: try scene.post.requireID(), authorID: try scene.author.requireID(), body: "댓글",
            clientID: UUID())
        try await comment.create(on: db)
        let media = try await fixtures.media(
            uploadedBy: scene.author, in: scene.group, purpose: .sticker)
        let sticker = Sticker(
            groupID: try scene.group.requireID(), createdByID: try scene.author.requireID(),
            mediaID: try media.requireID(), clientID: UUID())
        try await sticker.create(on: db)

        try await app.test(
            .DELETE, "internal/admin/v1/comments/\(try comment.requireID())",
            headers: adminHeaders()
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        try await app.test(
            .DELETE, "internal/admin/v1/stickers/\(try sticker.requireID())",
            headers: adminHeaders()
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        expectNil(try await Comment.find(try comment.requireID(), on: db))
        expectNil(try await Sticker.find(try sticker.requireID(), on: db))
        expectNil(try await Media.find(try media.requireID(), on: db))
        let actions = try await ModerationLogEntry.query(on: db).all().map(\.action)
        XCTAssertEqual(Set(actions), [.deleteComment, .deleteSticker])
    }

    func testSuspendAndUnsuspend() async throws {
        let scene = try await scene()
        let userID = try scene.author.requireID()
        let until = Date().addingTimeInterval(86_400)

        try await app.test(
            .POST, "internal/admin/v1/users/\(userID)/suspend", headers: adminHeaders(),
            beforeRequest: { req in
                try req.content.encode(SuspendUserRequest(reason: "  ", until: nil), as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity)
        }
        try await app.test(
            .POST, "internal/admin/v1/users/\(userID)/suspend", headers: adminHeaders(),
            beforeRequest: { req in
                try req.content.encode(SuspendUserRequest(reason: "반복 신고", until: until), as: .json)
            }
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        let suspended = try unwrap(try await User.find(userID, on: db))
        XCTAssertTrue(suspended.isSuspended())
        XCTAssertEqual(suspended.suspensionReason, "반복 신고")

        // The suspended user is refused by the moderation routes.
        try await app.test(.GET, "api/v1/me/blocks", headers: try headers(as: suspended)) {
            res async throws in
            XCTAssertEqual(try errorBody(res).code, .accountSuspended)
        }
        try await app.test(.GET, "internal/admin/v1/reports", headers: adminHeaders()) {
            res async throws in
            let page = try decode(PilgrimAPI.Page<AdminReport>.self, from: res)
            XCTAssertNotNil(page.items.first?.targetUser?.suspendedUntil)
        }

        try await app.test(
            .POST, "internal/admin/v1/users/\(userID)/unsuspend", headers: adminHeaders()
        ) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
        let restored = try unwrap(try await User.find(userID, on: db))
        XCTAssertFalse(restored.isSuspended())
        XCTAssertNil(restored.suspensionReason)
        let actions = try await ModerationLogEntry.query(on: db).sort(\.$createdAt).all().map(
            \.action)
        XCTAssertEqual(actions, [.suspendUser, .unsuspendUser])
    }

    func testStatusCounts() async throws {
        _ = try await scene()
        try await app.test(.GET, "internal/admin/v1/status", headers: adminHeaders()) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
            let status = try decode(AdminStatusResponse.self, from: res)
            XCTAssertEqual(status.counts.users, 2)
            XCTAssertEqual(status.counts.groups, 1)
            XCTAssertEqual(status.counts.posts, 1)
            XCTAssertEqual(status.counts.openReports, 1)
            XCTAssertEqual(status.counts.pendingPush, 0)
        }
    }

    func testMediaIs404WithoutTheFile() async throws {
        let scene = try await scene()
        let media = try await fixtures.media(
            uploadedBy: scene.author, in: scene.group, post: scene.post)
        try await app.test(
            .GET, "internal/admin/v1/media/\(try media.requireID())", headers: adminHeaders()
        ) { res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
    }
}

// XCTest's assertions take autoclosures, which cannot `await`; these evaluate first.
private func expectEqual<T: Equatable>(
    _ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs, rhs, file: file, line: line)
}

private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, file: file, line: line)
}
