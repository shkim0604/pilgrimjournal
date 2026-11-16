import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// `groups/:id/stickers` and `stickers/:id` against Postgres (design.md 8절).
final class StickerRoutesTests: DatabaseTestCase {
    private func createSticker(
        in group: Group, as user: User, mediaID: UUID, name: String? = nil,
        clientID: UUID = UUID(), file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        try await sendV1(
            .POST, "groups/\(try group.requireID())/stickers", as: user,
            json: CreateStickerRequest(clientId: clientID, mediaId: mediaID, name: name),
            file: file, line: line)
    }

    /// An unattached `sticker` upload row of `user` in `group` (no file).
    private func stickerUpload(by user: User, in group: Group) async throws -> UUID {
        try await fixtures.media(uploadedBy: user, in: group, purpose: .sticker).requireID()
    }

    func testCreateListAndRepeat() async throws {
        let admin = try await fixtures.user("관리자")
        let member = try await fixtures.user("멤버")
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])

        let upload = try await mediaUpload(
            "sticker", groupID: try group.requireID(), as: member,
            jpeg: TestJPEG.make(width: 256, height: 256))
        assertStatus(upload, .created)
        let mediaID = try decode(UploadResponse.self, from: upload).media.id
        let clientID = UUID()

        let created = try await createSticker(
            in: group, as: member, mediaID: mediaID, name: "  기쁨 ", clientID: clientID)
        assertStatus(created, .created)
        let sticker = try decode(StickerResponse.self, from: created)
        XCTAssertEqual(sticker.name, "기쁨")
        XCTAssertEqual(sticker.groupId, try group.requireID())
        XCTAssertEqual(sticker.media.id, mediaID)
        XCTAssertEqual(sticker.media.width, 256)
        XCTAssertTrue(sticker.isMine)
        XCTAssertEqual(sticker.createdBy?.id, try member.requireID())
        XCTAssertEqual(sticker.createdBy?.displayName, "멤버")
        expectNotNil(try await Media.find(mediaID, on: db)?.attachedAt)

        let repeated = try await createSticker(
            in: group, as: member, mediaID: UUID(), name: "다른 이름", clientID: clientID)
        assertStatus(repeated, .ok)
        XCTAssertEqual(try decode(StickerResponse.self, from: repeated).id, sticker.id)
        expectEqual(try await Sticker.query(on: db).count(), 1)

        let second = try await createSticker(
            in: group, as: admin, mediaID: try await stickerUpload(by: admin, in: group))
        assertStatus(second, .created)

        let list = try decode(
            [StickerResponse].self,
            from: try await sendV1(.GET, "groups/\(try group.requireID())/stickers", as: admin))
        XCTAssertEqual(
            list.map(\.id), [sticker.id, try decode(StickerResponse.self, from: second).id])
        XCTAssertEqual(list.map(\.isMine), [false, true])
        XCTAssertNil(list[1].name)

        try assertError(
            try await sendV1(.GET, "groups/\(try group.requireID())/stickers", as: outsider), 404,
            .notFound)
        try assertError(
            try await createSticker(
                in: group, as: outsider, mediaID: try await stickerUpload(by: admin, in: group)),
            404, .notFound)
    }

    func testOnlyYourOwnUnattachedStickerUploadForThisGroupAttaches() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let otherGroup = try await fixtures.group(admin: admin, members: [member])

        let othersUpload = try await stickerUpload(by: admin, in: group)
        let postPhoto = try await fixtures.media(uploadedBy: member, in: group, purpose: .post)
        let elsewhere = try await stickerUpload(by: member, in: otherGroup)
        let used = try await makeSticker(by: member, in: group)
        for mediaID in [
            othersUpload, try postPhoto.requireID(), elsewhere, used.$media.id, UUID(),
        ] {
            try assertError(
                try await createSticker(in: group, as: member, mediaID: mediaID), 409,
                .mediaNotAttachable)
        }
        expectEqual(try await Sticker.query(on: db).count(), 1)
        expectNil(try await Media.find(othersUpload, on: db)?.attachedAt)
    }

    func testAGroupHoldsThirtyStickers() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let other = try await fixtures.group(admin: admin)
        for _ in 0..<APILimits.stickersPerGroup {
            try await makeSticker(by: admin, in: group)
        }
        let upload = try await stickerUpload(by: admin, in: group)
        let full = try await createSticker(in: group, as: admin, mediaID: upload)
        try assertError(full, 409, .stickerLimitReached)
        XCTAssertEqual(try errorBody(full).limit, APILimits.stickersPerGroup)
        expectNil(try await Media.find(upload, on: db)?.attachedAt)

        assertStatus(
            try await createSticker(
                in: other, as: admin, mediaID: try await stickerUpload(by: admin, in: other)),
            .created)
    }

    func testNameRulesAndGroupState() async throws {
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        try assertError(
            try await createSticker(
                in: group, as: admin, mediaID: try await stickerUpload(by: admin, in: group),
                name: String(repeating: "가", count: 21)),
            422, .limitExceeded)

        try await setStatus(.voting, of: group)
        assertStatus(
            try await createSticker(
                in: group, as: admin, mediaID: try await stickerUpload(by: admin, in: group)),
            .created)

        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await createSticker(
                in: group, as: admin, mediaID: try await stickerUpload(by: admin, in: group)),
            409, .groupPendingDeletion)
    }

    func testDeletePermissions() async throws {
        let admin = try await fixtures.user()
        let creator = try await fixtures.user()
        let member = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [creator, member])

        let first = try await makeSticker(by: creator, in: group)
        let firstID = try first.requireID()
        try assertError(
            try await sendV1(.DELETE, "stickers/\(firstID)", as: outsider), 404, .notFound)
        try assertError(
            try await sendV1(.DELETE, "stickers/\(firstID)", as: member), 403, .forbidden)
        assertStatus(try await sendV1(.DELETE, "stickers/\(firstID)", as: admin), .noContent)
        try assertError(try await sendV1(.DELETE, "stickers/\(firstID)", as: admin), 404, .notFound)

        // While an admin vote is open only the creator may delete.
        let second = try await makeSticker(by: creator, in: group)
        let secondID = try second.requireID()
        try await setStatus(.voting, of: group)
        try assertError(
            try await sendV1(.DELETE, "stickers/\(secondID)", as: admin), 409,
            .adminVoteInProgress)
        assertStatus(try await sendV1(.DELETE, "stickers/\(secondID)", as: creator), .noContent)

        // A creator who left: the sticker stays, and they can no longer reach it.
        try await setStatus(.active, of: group)
        group.$admin.id = try admin.requireID()
        try await group.save(on: db)
        let third = try await makeSticker(by: creator, in: group)
        let creatorID = try creator.requireID()
        try await Membership.query(on: db).filter(\.$user.$id == creatorID).delete()
        try assertError(
            try await sendV1(.DELETE, "stickers/\(try third.requireID())", as: creator), 404,
            .notFound)
        expectNotNil(try await Sticker.find(try third.requireID(), on: db))
    }

    func testDeleteRemovesReactionsAndPhotoAndMarksComments() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member])
        let sticker = try await makeSticker(by: member, in: group)
        let stickerID = try sticker.requireID()
        let keptSticker = try await makeSticker(by: member, in: group)
        let post = try await fixtures.post(by: admin, in: group)
        let postID = try post.requireID()
        try await Reaction(postID: postID, userID: try admin.requireID(), key: .sticker(stickerID))
            .create(on: db)
        try await Reaction(
            postID: postID, userID: try admin.requireID(),
            key: .sticker(try keptSticker.requireID())
        ).create(on: db)
        try await Reaction(postID: postID, userID: try member.requireID(), key: .emoji("🙏"))
            .create(on: db)
        let comment = Comment(
            postID: postID, authorID: try admin.requireID(), body: "", stickerID: stickerID,
            clientID: UUID())
        try await comment.create(on: db)

        assertStatus(try await sendV1(.DELETE, "stickers/\(stickerID)", as: member), .noContent)

        expectNil(try await Sticker.find(stickerID, on: db))
        expectNil(try await Media.find(sticker.$media.id, on: db))
        let queued = try await MediaFileDeletion.query(on: db).all().map(\.filePath)
        XCTAssertEqual(queued, [MediaPaths.relativePath(for: sticker.$media.id)])
        let keys = try await Reaction.query(on: db).all().compactMap(\.key)
        XCTAssertEqual(Set(keys), [.sticker(try keptSticker.requireID()), .emoji("🙏")])

        let comments = try decode(
            APIPage<CommentResponse>.self,
            from: try await sendV1(.GET, "posts/\(postID)/comments", as: admin))
        XCTAssertEqual(comments.items.count, 1)
        XCTAssertNil(comments.items[0].sticker)
        XCTAssertTrue(comments.items[0].stickerRemoved)
    }
}
