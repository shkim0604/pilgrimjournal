#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

@MainActor
final class GroupsContentDetailTests: XCTestCase {
    private func detail(
        _ fixture: GroupsContentFixture, _ post: PostResponse, isAdmin: Bool = false
    ) async -> GroupPostDetailModel {
        let model = GroupPostDetailModel(
            api: fixture.api, postID: post.id, groupID: post.groupId, isAdmin: isAdmin,
            events: fixture.events)
        await model.load()
        return model
    }

    func testLoadsPostCommentsAndGoneState() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = await detail(fixture, prayer)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.comments.map(\.body), ["함께 기도할게요 🙏"])

        let missing = GroupPostDetailModel(
            api: fixture.api, postID: UUID(), groupID: fixture.wednesday.id, isAdmin: false,
            events: nil)
        await missing.load()
        XCTAssertEqual(missing.state, .gone)
    }

    func testReactionToggle() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = await detail(fixture, prayer)
        let pray = ReactionKey.emoji("🙏")
        XCTAssertEqual(model.post?.reactions.first { $0.key == pray }?.count, 2)
        XCTAssertFalse(model.hasReacted(pray))

        await model.toggleReaction(pray)
        XCTAssertEqual(model.post?.reactions.first { $0.key == pray }?.count, 3)
        XCTAssertTrue(model.hasReacted(pray))

        await model.toggleReaction(pray)
        XCTAssertEqual(model.post?.reactions.first { $0.key == pray }?.count, 2)
        XCTAssertFalse(model.hasReacted(pray))
        let server = try await fixture.api.post(id: prayer.id)
        XCTAssertFalse(server.reactions.contains { $0.reactedByMe })
    }

    func testAtMostTenDistinctReactionsPerPost() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = await detail(fixture, prayer)
        let emoji = ["🙏", "❤️", "🙌", "😢", "😊", "👍", "🔥", "✨", "🎉", "😀"]
        for item in emoji { await model.toggleReaction(.emoji(item)) }
        XCTAssertEqual(model.myReactionCount, 10)
        XCTAssertNil(model.notice)

        let eleventh = ReactionKey.emoji("🌱")
        XCTAssertFalse(model.canAddReaction(eleventh))
        XCTAssertTrue(model.canAddReaction(.emoji("🙏")), "removing is always allowed")
        await model.toggleReaction(eleventh)
        XCTAssertEqual(model.notice, "반응은 한 글에 10개까지 남길 수 있어요")
        let server = try await fixture.api.post(id: prayer.id)
        XCTAssertEqual(server.reactions.filter(\.reactedByMe).count, 10)
        XCTAssertFalse(server.reactions.contains { $0.key == eleventh })
    }

    func testOnlyBookReportsExtend() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = await detail(fixture, try await fixture.post(.prayer, in: fixture.wednesday))
        XCTAssertFalse(prayer.canExtend)
        XCTAssertNil(prayer.extendedExpiryPreview)
        let extendedPrayer = await prayer.extendDiscussion()
        XCTAssertFalse(extendedPrayer)

        let reportPost = try await fixture.post(.bookReport, in: fixture.wednesday)
        let report = await detail(fixture, reportPost)
        XCTAssertTrue(report.canExtend)
        let preview = try XCTUnwrap(report.extendedExpiryPreview)
        XCTAssertEqual(preview, reportPost.expiresAt + 7 * 86_400)
        let extended = await report.extendDiscussion()
        XCTAssertTrue(extended)
        XCTAssertEqual(report.post?.expiresAt, preview)
        XCTAssertEqual(report.post?.extensionCount, 1)
    }

    func testCommentsWithTextStickerAndDelete() async throws {
        let fixture = try await GroupsContentFixture()
        let testimony = try await fixture.post(.testimony, in: fixture.wednesday)
        let model = await detail(fixture, testimony)
        XCTAssertFalse(model.canSendComment)

        model.commentText = "  아멘  "
        let sent = await model.sendComment()
        XCTAssertTrue(sent)
        XCTAssertEqual(model.comments.last?.body, "아멘")
        XCTAssertEqual(model.post?.commentCount, 1)
        XCTAssertEqual(model.commentText, "")

        model.commentText = String(repeating: "가", count: 501)
        XCTAssertFalse(model.canSendComment)
        model.commentText = ""

        let comment = try XCTUnwrap(model.comments.last)
        XCTAssertTrue(model.canDelete(comment))
        let deleted = await model.deleteComment(comment)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.comments.isEmpty)
        XCTAssertEqual(model.post?.commentCount, 0)
    }

    func testStickerCreateReactAndDelete() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = await detail(fixture, prayer)
        let photo = try GroupsContentFixture.jpeg(width: 400, height: 300)
        let jpeg = try XCTUnwrap(GroupStickerCropper.squareJPEG(from: photo))

        let created = await model.createSticker(jpeg: jpeg, name: " 기쁨 ")
        let sticker = try XCTUnwrap(created)
        XCTAssertEqual(sticker.name, "기쁨")
        XCTAssertEqual(model.stickers.map(\.id), [sticker.id])

        await model.toggleReaction(.sticker(sticker.id))
        XCTAssertTrue(model.hasReacted(.sticker(sticker.id)))
        model.commentSticker = sticker
        let sent = await model.sendComment()
        XCTAssertTrue(sent)
        XCTAssertEqual(model.comments.last?.sticker?.id, sticker.id)

        XCTAssertTrue(model.canDelete(sticker))
        let deleted = await model.deleteSticker(sticker)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.stickers.isEmpty)
        XCTAssertFalse(model.post?.reactions.contains { $0.key == .sticker(sticker.id) } ?? true)
        XCTAssertEqual(model.comments.last?.stickerRemoved, true, "지워진 스티커")

        await model.reloadComments()
        XCTAssertEqual(model.comments.last?.stickerRemoved, true, "the server agrees")
    }

    func testStickerCropIsSquare256() throws {
        let photo = try GroupsContentFixture.jpeg(width: 400, height: 300)
        let jpeg = try XCTUnwrap(GroupStickerCropper.squareJPEG(from: photo, position: 1))
        let size = try XCTUnwrap(GroupImageMetrics.pixelSize(of: jpeg))
        XCTAssertEqual(size.width, 256)
        XCTAssertEqual(size.height, 256)
        XCTAssertTrue(PhotoLimits.hasJPEGSignature(jpeg))

        XCTAssertEqual(
            GroupStickerCropper.cropRect(width: 400, height: 300, position: 0),
            CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(
            GroupStickerCropper.cropRect(width: 400, height: 300, position: 1),
            CGRect(x: 100, y: 0, width: 300, height: 300))
        XCTAssertEqual(
            GroupStickerCropper.cropRect(width: 300, height: 500, position: 0.5),
            CGRect(x: 0, y: 100, width: 300, height: 300))
    }

    func testAuthorOrAdminDeletesThePost() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        XCTAssertFalse(prayer.isMine)

        let member = await detail(fixture, prayer, isAdmin: false)
        XCTAssertFalse(member.canDeletePost)
        let memberDeleted = await member.deletePost()
        XCTAssertFalse(memberDeleted)

        let admin = await detail(fixture, prayer, isAdmin: true)
        XCTAssertTrue(admin.canDeletePost)
        let adminDeleted = await admin.deletePost()
        XCTAssertTrue(adminDeleted)
        XCTAssertEqual(admin.state, .gone)
        XCTAssertFalse(feed.posts.contains { $0.id == prayer.id })
        do {
            _ = try await fixture.api.post(id: prayer.id)
            XCTFail("the post is gone")
        } catch {
            XCTAssertTrue(GroupContentError.isGone(error))
        }
    }

    func testHidePostHidePersonAndBlockReachTheServer() async throws {
        let fixture = try await GroupsContentFixture()
        let feed = fixture.feed(fixture.wednesday)
        await feed.refresh()

        let testimony = try await fixture.post(.testimony, in: fixture.wednesday)
        let mine = await detail(fixture, testimony)
        let selfHide = await mine.hide(testimony.author)
        XCTAssertFalse(selfHide, "cannot hide yourself")
        XCTAssertNotNil(mine.notice)

        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let hidePost = await detail(fixture, prayer)
        let hidden = await hidePost.hidePost()
        XCTAssertTrue(hidden)
        XCTAssertEqual(hidePost.state, .gone)
        let hides = try await fixture.api.hides()
        XCTAssertEqual(hides.posts.map(\.postId), [prayer.id])
        XCTAssertFalse(feed.posts.contains { $0.id == prayer.id })

        let report = try await fixture.post(.bookReport, in: fixture.wednesday)
        let hidePerson = await detail(fixture, report)
        let personHidden = await hidePerson.hide(report.author)
        XCTAssertTrue(personHidden)
        XCTAssertEqual(hidePerson.state, .gone)
        let hidesAfter = try await fixture.api.hides()
        XCTAssertEqual(hidesAfter.users.map(\.user.id), [report.author.id])

        let books = try await fixture.post(.bookReport, in: fixture.books)
        let blockModel = await detail(fixture, books)
        let blocked = await blockModel.block(books.author)
        XCTAssertTrue(blocked)
        let blockedUsers = try await fixture.api.blockedUsers()
        XCTAssertEqual(blockedUsers.map(\.id), [books.author.id])
    }

    func testBlockingACommenterRemovesTheirComments() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = await detail(fixture, prayer)
        let commenter = try XCTUnwrap(model.comments.first?.author)

        let blocked = await model.block(commenter)
        XCTAssertTrue(blocked)
        XCTAssertEqual(model.state, .loaded, "the post stays")
        XCTAssertTrue(model.comments.isEmpty)
        XCTAssertEqual(model.post?.commentCount, 0)
    }
}

@MainActor
final class GroupsContentSafetyTests: XCTestCase {
    func testReportSendsReasonNoteAndOneClientID() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let model = GroupReportModel(
            api: fixture.api, target: .post(prayer.id), groupID: fixture.wednesday.id)
        XCTAssertFalse(model.canSubmit, "a reason is required")

        model.reason = .harassment
        model.note = String(repeating: "가", count: 501)
        XCTAssertFalse(model.canSubmit)
        model.note = "  반복해서 올려요  "
        let request = try XCTUnwrap(model.request)
        XCTAssertEqual(request.targetType, .post)
        XCTAssertEqual(request.targetId, prayer.id)
        XCTAssertEqual(request.reason, .harassment)
        XCTAssertEqual(request.note, "반복해서 올려요")

        let submitted = await model.submit()
        XCTAssertTrue(submitted)
        let receipt = try XCTUnwrap(model.receipt)
        XCTAssertFalse(model.canSubmit, "one report per sheet")
        let again = try await fixture.api.report(request)
        XCTAssertEqual(again.id, receipt.id, "the same clientId is idempotent")
    }

    func testReportingYourselfFails() async throws {
        let fixture = try await GroupsContentFixture()
        let me = await fixture.api.currentUserID
        let model = GroupReportModel(
            api: fixture.api, target: .user(UserSummary(id: me, displayName: "나")),
            groupID: fixture.wednesday.id)
        model.reason = .other
        let submitted = await model.submit()
        XCTAssertFalse(submitted)
        XCTAssertEqual(model.errorMessage, "자기 자신에게는 할 수 없어요")
    }

    func testBlockedUsersListAndUnblock() async throws {
        let fixture = try await GroupsContentFixture()
        let author = try await fixture.post(.prayer, in: fixture.wednesday).author
        try await fixture.api.block(userID: author.id)

        let model = BlockedUsersModel(api: fixture.api)
        await model.load()
        XCTAssertEqual(model.users.map(\.id), [author.id])
        let unblocked = await model.unblock(author)
        XCTAssertTrue(unblocked)
        XCTAssertTrue(model.users.isEmpty)
        let remaining = try await fixture.api.blockedUsers()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testHiddenItemsListAndUnhide() async throws {
        let fixture = try await GroupsContentFixture()
        let prayer = try await fixture.post(.prayer, in: fixture.wednesday)
        let report = try await fixture.post(.bookReport, in: fixture.wednesday)
        try await fixture.api.hidePost(id: prayer.id)
        try await fixture.api.hideUser(id: report.author.id)

        let model = HiddenItemsModel(api: fixture.api)
        await model.load()
        XCTAssertEqual(model.posts.map(\.postId), [prayer.id])
        XCTAssertEqual(model.posts.first?.groupName, "수요 기도모임")
        XCTAssertEqual(model.users.map(\.user.id), [report.author.id])

        let post = try XCTUnwrap(model.posts.first)
        let postShown = await model.unhide(post)
        XCTAssertTrue(postShown)
        let user = try XCTUnwrap(model.users.first)
        let userShown = await model.unhide(user)
        XCTAssertTrue(userShown)
        XCTAssertTrue(model.isEmpty)
        let hides = try await fixture.api.hides()
        XCTAssertTrue(hides.posts.isEmpty && hides.users.isEmpty)
        let visible = try await fixture.posts(in: fixture.wednesday)
        XCTAssertTrue(visible.contains { $0.id == prayer.id })
    }
}
#endif
