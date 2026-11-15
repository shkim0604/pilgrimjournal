import Crypto
import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// `POST /uploads`, `GET /media/:id` and the signed file route against Postgres.
final class MediaRoutesTests: DatabaseTestCase {
    private func uploaded(_ response: XCTHTTPResponse) throws -> MediaRef {
        try decode(UploadResponse.self, from: response).media
    }

    func testUploadStoresAStrippedJPEGAndRepeatsByClientID() async throws {
        let alice = try await fixtures.user("앨리스")
        let group = try await fixtures.group(admin: alice)
        let groupID = try group.requireID()
        let clientID = UUID()

        let first = try await mediaUpload(
            "post", groupID: groupID, as: alice,
            jpeg: TestJPEG.make(width: 1_200, height: 900, metadata: true), clientID: clientID)
        assertStatus(first, .created)
        let ref = try uploaded(first)
        XCTAssertEqual(ref.width, 1_200)
        XCTAssertEqual(ref.height, 900)
        let expected = TestJPEG.stripped(width: 1_200, height: 900)
        XCTAssertEqual(ref.byteCount, expected.count)

        let row = try unwrap(try await Media.find(ref.id, on: db))
        XCTAssertEqual(row.purpose, .post)
        XCTAssertEqual(row.$group.id, groupID)
        XCTAssertEqual(row.$uploader.id, try alice.requireID())
        XCTAssertNil(row.attachedAt)
        XCTAssertNil(row.$post.id)
        XCTAssertEqual(row.filePath, MediaPaths.relativePath(for: ref.id))
        XCTAssertEqual(row.contentType, "image/jpeg")
        XCTAssertEqual(row.sha256, Data(SHA256.hash(data: expected)))
        let stored = try await app.mediaStore.read(row.filePath)
        XCTAssertEqual(stored, expected)
        XCTAssertFalse(String(decoding: stored ?? Data(), as: UTF8.self).contains("GPS"))

        // Same clientId, different file: the first upload comes back and nothing new is kept.
        let repeated = try await mediaUpload(
            "post", groupID: groupID, as: alice, jpeg: TestJPEG.make(width: 10, height: 10),
            clientID: clientID)
        assertStatus(repeated, .ok)
        XCTAssertEqual(try uploaded(repeated).id, ref.id)
        expectEqual(try await Media.query(on: db).count(), 1)
    }

    func testProfilePhotosNeedNoGroupOrFinishedSignUp() async throws {
        let newcomer = try await fixtures.user(nil)
        let response = try await mediaUpload(
            "profile", groupID: nil, as: newcomer, jpeg: TestJPEG.make(width: 600, height: 600))
        assertStatus(response, .created)
        let row = try unwrap(try await Media.find(try uploaded(response).id, on: db))
        XCTAssertEqual(row.purpose, .profile)
        XCTAssertNil(row.$group.id)

        // Group photos do need a finished sign-up.
        let admin = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [newcomer])
        try assertError(
            try await mediaUpload(
                "post", groupID: try group.requireID(), as: newcomer, jpeg: TestJPEG.make()),
            403, .signupRequired)
    }

    func testGroupPhotosNeedMembershipAndAWritableGroup() async throws {
        let admin = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin)
        let groupID = try group.requireID()

        try assertError(
            try await mediaUpload("post", groupID: groupID, as: outsider, jpeg: TestJPEG.make()),
            404, .notFound)
        try assertError(
            try await mediaUpload("sticker", groupID: UUID(), as: admin, jpeg: TestJPEG.make()),
            404, .notFound)
        try assertError(
            try await mediaUpload("comment", groupID: nil, as: admin, jpeg: TestJPEG.make()),
            422, .validationFailed)
        try assertError(
            try await mediaUpload("banner", groupID: groupID, as: admin, jpeg: TestJPEG.make()),
            422, .validationFailed)

        try await setStatus(.pendingDeletion, of: group)
        try assertError(
            try await mediaUpload("post", groupID: groupID, as: admin, jpeg: TestJPEG.make()),
            409, .groupPendingDeletion)

        admin.suspendedAt = Date()
        try await admin.save(on: db)
        try assertError(
            try await mediaUpload("profile", groupID: nil, as: admin, jpeg: TestJPEG.make()),
            403, .accountSuspended)
        expectEqual(try await Media.query(on: db).count(), 0)
    }

    func testUploadChecksTypeSizeAndDimensions() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let groupID = try group.requireID()

        try assertError(
            try await mediaUpload(
                "post", groupID: groupID, as: alice, jpeg: TestJPEG.make(),
                partContentType: "image/png"),
            422, .mediaInvalid)
        try assertError(
            try await mediaUpload(
                "post", groupID: groupID, as: alice, jpeg: Data("not a photo".utf8)),
            422, .mediaInvalid)
        try assertError(
            try await mediaUpload(
                "sticker", groupID: groupID, as: alice,
                jpeg: TestJPEG.make(width: 300, height: 300)),
            422, .mediaInvalid)
        try assertError(
            try await mediaUpload(
                "post", groupID: groupID, as: alice,
                jpeg: TestJPEG.make(width: 1_700, height: 1_000)),
            422, .mediaInvalid)
        let tooLarge = try await mediaUpload(
            "post", groupID: groupID, as: alice,
            jpeg: TestJPEG.make(width: 800, height: 600, byteCount: PhotoLimits.maxPhotoBytes + 1))
        try assertError(tooLarge, 413, .mediaTooLarge)
        XCTAssertEqual(try errorBody(tooLarge).limit, PhotoLimits.maxPhotoBytes)

        expectEqual(try await Media.query(on: db).count(), 0)
        let leftovers = FileManager.default.enumerator(atPath: mediaRoot.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(leftovers ?? [], [])
    }

    func testMediaURLsFollowWhoMaySeeThePhoto() async throws {
        let author = try await fixtures.user("작성자")
        let member = try await fixtures.user("멤버")
        let blocked = try await fixtures.user("차단")
        let outsider = try await fixtures.user("밖")
        let group = try await fixtures.group(admin: author, members: [member, blocked])
        let post = try await fixtures.post(by: author, in: group)
        let photo = try await fixtures.media(uploadedBy: author, in: group, post: post)
        let photoID = try photo.requireID()
        try await fixtures.block(blocked, author)

        let answer = try await sendV1(.GET, "media/\(photoID)", as: member)
        assertStatus(answer, .ok)
        let fresh = try decode(MediaURLResponse.self, from: answer)
        XCTAssertTrue(
            fresh.url.path.hasSuffix("/api/media-files/\(photoID.uuidString.lowercased())"))
        XCTAssertGreaterThan(fresh.expiresAt, Date())
        assertStatus(try await sendV1(.GET, "media/\(photoID)", as: author), .ok)
        try assertError(try await sendV1(.GET, "media/\(photoID)", as: blocked), 404, .notFound)
        try assertError(try await sendV1(.GET, "media/\(photoID)", as: outsider), 404, .notFound)
        try assertError(try await sendV1(.GET, "media/\(UUID())", as: member), 404, .notFound)

        // An unattached upload: its uploader only.
        let pending = try await fixtures.media(uploadedBy: member, in: group)
        assertStatus(try await sendV1(.GET, "media/\(try pending.requireID())", as: member), .ok)
        try assertError(
            try await sendV1(.GET, "media/\(try pending.requireID())", as: author), 404, .notFound)

        // An expired post's photo is gone for members too.
        let old = try await fixtures.post(
            by: author, in: group, expiresAt: Date().addingTimeInterval(-60))
        let oldPhoto = try await fixtures.media(uploadedBy: author, in: group, post: old)
        try assertError(
            try await sendV1(.GET, "media/\(try oldPhoto.requireID())", as: member), 404,
            .notFound)

        // A profile photo: people who share a group with its owner.
        let portrait = try await fixtures.media(uploadedBy: author, in: nil, purpose: .profile)
        portrait.attachedAt = Date()
        try await portrait.save(on: db)
        author.$profileMedia.id = try portrait.requireID()
        try await author.save(on: db)
        assertStatus(try await sendV1(.GET, "media/\(try portrait.requireID())", as: member), .ok)
        try assertError(
            try await sendV1(.GET, "media/\(try portrait.requireID())", as: outsider), 404,
            .notFound)
    }

    func testStickerAndCommentPhotosFollowTheirGroupAndAuthor() async throws {
        let admin = try await fixtures.user()
        let member = try await fixtures.user()
        let hider = try await fixtures.user()
        let outsider = try await fixtures.user()
        let group = try await fixtures.group(admin: admin, members: [member, hider])
        let sticker = try await makeSticker(by: admin, in: group)
        let stickerMedia = sticker.$media.id
        assertStatus(try await sendV1(.GET, "media/\(stickerMedia)", as: member), .ok)
        try assertError(
            try await sendV1(.GET, "media/\(stickerMedia)", as: outsider), 404, .notFound)

        let post = try await fixtures.post(by: admin, in: group)
        let comment = Comment(
            postID: try post.requireID(), authorID: try member.requireID(), body: "",
            clientID: UUID())
        try await comment.create(on: db)
        let photo = try await fixtures.media(uploadedBy: member, in: group, purpose: .comment)
        photo.$comment.id = try comment.requireID()
        photo.attachedAt = Date()
        try await photo.save(on: db)
        try await fixtures.hide(user: member, by: hider)
        assertStatus(try await sendV1(.GET, "media/\(try photo.requireID())", as: admin), .ok)
        try assertError(
            try await sendV1(.GET, "media/\(try photo.requireID())", as: hider), 404, .notFound)
    }

    func testSignedFileServesTheStoredJPEG() async throws {
        let alice = try await fixtures.user()
        let group = try await fixtures.group(admin: alice)
        let response = try await mediaUpload(
            "post", groupID: try group.requireID(), as: alice,
            jpeg: TestJPEG.make(metadata: true))
        let ref = try uploaded(response)

        let file = try await mediaFetch(ref.url)
        assertStatus(file, .ok)
        XCTAssertEqual(Data(buffer: file.body), TestJPEG.stripped())
        XCTAssertEqual(file.headers.contentType, .jpeg)
        XCTAssertEqual(file.headers.first(name: .cacheControl), "private, max-age=600")

        let expired = MediaURLSigner(config: app.pilgrimConfig)
            .signedURL(for: ref.id, now: Date().addingTimeInterval(-601))
        try assertError(try await mediaFetch(expired.url), 403, .forbidden)

        // Once the row is gone (and the file queued), the URL stops working.
        try await Media.query(on: db).filter(\.$id == ref.id).delete()
        try assertError(try await mediaFetch(ref.url), 404, .notFound)
        let queued = try await MediaFileDeletion.query(on: db).all().map(\.filePath)
        XCTAssertEqual(queued, [MediaPaths.relativePath(for: ref.id)])
    }
}
