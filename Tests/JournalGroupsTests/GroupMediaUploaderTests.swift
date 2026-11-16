#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class GroupMediaUploaderTests: XCTestCase {
    private let clientID = UUID(uuidString: "0A0B0C0D-0000-0000-0000-000000000001")!
    private let groupID = UUID(uuidString: "0A0B0C0D-0000-0000-0000-000000000002")!

    func testMultipartBodyLayout() {
        let upload = GroupMediaUpload(
            clientID: clientID, purpose: .comment, groupID: groupID,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1, height: 1)

        let form = GroupMediaUploader.multipartForm(for: upload, boundary: "BOUNDARY")

        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUNDARY")
        let c = clientID.uuidString.lowercased()
        let g = groupID.uuidString.lowercased()
        var expected = Data()
        expected.append(
            Data(
                ("--BOUNDARY\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\ncomment\r\n"
                    + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"clientId\"\r\n\r\n\(c)\r\n"
                    + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"groupId\"\r\n\r\n\(g)\r\n"
                    + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; "
                    + "filename=\"\(c).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n").utf8))
        expected.append(Data([0xFF, 0xD8, 0xFF, 0xD9]))
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        XCTAssertEqual(form.body, expected)
    }

    func testProfileUploadsHaveNoGroupID() throws {
        let image = CompressedImage(data: Data([0xFF, 0xD8]), width: 10, height: 20, quality: 0.7)
        let upload = image.upload(purpose: .profile, groupID: groupID, clientID: clientID)
        XCTAssertNil(upload.groupID)
        XCTAssertEqual(upload.width, 10)
        let body = String(
            decoding: GroupMediaUploader.multipartForm(for: upload).body, as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"groupId\""))
        XCTAssertTrue(body.contains("profile"))
    }

    func testUploadPipelineCompressesAndSendsMultipart() async throws {
        let mediaID = UUID()
        let transport = FakeHTTPTransport { request in
            try Fixture.json(
                request,
                UploadResponse(
                    media: Fixture.mediaRef(id: mediaID, expiresAt: Fixture.now + 600)),
                status: 201)
        }
        let (api, _) = Fixture.api(transport: transport)
        let png = try TestImages.png(width: 300, height: 200, alpha: true)

        let ref = try await GroupMediaUploader(api: api).upload(
            imageData: png, purpose: .post, groupID: groupID, clientID: clientID)

        XCTAssertEqual(ref.id, mediaID)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/uploads")
        XCTAssertEqual(request.httpMethod, "POST")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertNotNil(body.range(of: Data("Content-Type: image/jpeg\r\n\r\n".utf8)))
        XCTAssertNotNil(body.range(of: Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNotNil(body.range(of: Data(groupID.uuidString.lowercased().utf8)))
    }

    func testMediaURLCacheReusesValidURLsAndRefreshesExpiredOnesOnce() async throws {
        let calls = Counter()
        let fresh = URL(string: "https://pilgrim.delight-house.org/api/media-files/x?exp=2")!
        let transport = FakeHTTPTransport { request in
            calls.increment()
            try await Task.sleep(for: .milliseconds(50))
            return try Fixture.json(
                request, MediaURLResponse(url: fresh, expiresAt: Fixture.now + 600))
        }
        let (api, _) = Fixture.api(transport: transport)
        let cache = GroupMediaURLCache(api: api, now: { Fixture.now })

        let valid = Fixture.mediaRef(expiresAt: Fixture.now + 300)
        let cachedURL = try await cache.url(for: valid)
        XCTAssertEqual(cachedURL, valid.url)
        XCTAssertEqual(calls.value, 0)

        let expired = Fixture.mediaRef(expiresAt: Fixture.now + 10)
        await cache.remember([expired])
        async let a = cache.url(forMediaID: expired.id)
        async let b = cache.url(forMediaID: expired.id)
        async let c = cache.url(forMediaID: expired.id)
        let urls = try await [a, b, c]
        XCTAssertEqual(urls, [fresh, fresh, fresh])
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(
            transport.requests.first?.url?.path,
            "/api/v1/media/\(expired.id.uuidString.lowercased())")

        _ = try await cache.url(forMediaID: expired.id)
        XCTAssertEqual(calls.value, 1)
    }
}
#endif
