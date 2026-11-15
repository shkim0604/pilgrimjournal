import Foundation
import PilgrimAPI
import Vapor
import XCTest

@testable import PilgrimServerCore

/// `UploadValidation` (type, size, dimensions per purpose) and `UploadFields` parsing.
final class UploadValidationTests: XCTestCase {
    private func validate(
        _ purpose: MediaPurpose, _ data: Data, type: HTTPMediaType? = .jpeg
    ) throws -> SanitizedJPEG {
        try UploadValidation.validate(purpose: purpose, contentType: type, data: data)
    }

    func testAcceptsPhotosWithinTheLimitsAndStripsThem() throws {
        let photo = try validate(.post, TestJPEG.make(width: 1_600, height: 1_200, metadata: true))
        XCTAssertEqual(photo.data, TestJPEG.stripped(width: 1_600, height: 1_200))
        XCTAssertEqual(photo.width, 1_600)
        XCTAssertEqual(photo.height, 1_200)
        for purpose: MediaPurpose in [.comment, .profile] {
            XCTAssertNoThrow(try validate(purpose, TestJPEG.make(width: 900, height: 1_600)))
        }
        let sticker = try validate(.sticker, TestJPEG.make(width: 256, height: 256))
        XCTAssertEqual(sticker.width, 256)
    }

    func testByteLimitsPerPurpose() throws {
        XCTAssertNoThrow(
            try validate(.post, TestJPEG.make(width: 800, height: 600, byteCount: 500 * 1_024)))
        let photo = mediaThrownAPIError {
            _ = try self.validate(
                .post, TestJPEG.make(width: 800, height: 600, byteCount: 500 * 1_024 + 1))
        }
        XCTAssertEqual(photo?.code, .mediaTooLarge)
        XCTAssertEqual(photo?.limit, PhotoLimits.maxPhotoBytes)
        XCTAssertEqual(photo?.httpStatus, 413)

        XCTAssertNoThrow(
            try validate(.sticker, TestJPEG.make(width: 256, height: 256, byteCount: 100 * 1_024)))
        let sticker = mediaThrownAPIError {
            _ = try self.validate(
                .sticker, TestJPEG.make(width: 256, height: 256, byteCount: 100 * 1_024 + 1))
        }
        XCTAssertEqual(sticker?.code, .mediaTooLarge)
        XCTAssertEqual(sticker?.limit, PhotoLimits.maxStickerBytes)
    }

    func testTheLimitAppliesToTheFileAsUploaded() {
        // Metadata that would bring the file under the limit once stripped still counts.
        var bytes = [UInt8](TestJPEG.make(width: 256, height: 256))
        let comments = (0..<2).flatMap { _ in
            TestJPEG.segment(0xFE, [UInt8](repeating: 0x41, count: 60_000))
        }
        bytes.insert(contentsOf: comments, at: 2)
        let error = mediaThrownAPIError { _ = try self.validate(.sticker, Data(bytes)) }
        XCTAssertEqual(error?.code, .mediaTooLarge)
    }

    func testDimensionsPerPurpose() {
        let cases: [(MediaPurpose, Int, Int)] = [
            (.post, 1_601, 1_000), (.comment, 1_000, 1_601), (.profile, 2_000, 2_000),
            (.sticker, 255, 256), (.sticker, 256, 257), (.sticker, 512, 512), (.post, 0, 600),
            (.post, 800, 0),
        ]
        for (purpose, width, height) in cases {
            let error = mediaThrownAPIError {
                _ = try self.validate(purpose, TestJPEG.make(width: width, height: height))
            }
            XCTAssertEqual(error?.code, .mediaInvalid, "\(purpose) \(width)x\(height)")
            XCTAssertEqual(error?.field, UploadFormField.file)
            XCTAssertEqual(error?.httpStatus, 422)
        }
    }

    func testTypeAndSignatureMustBeJPEG() {
        for type: HTTPMediaType? in [
            nil, .png, .binary, HTTPMediaType(type: "image", subType: "heic"),
        ] {
            let error = mediaThrownAPIError {
                _ = try self.validate(.post, TestJPEG.make(), type: type)
            }
            XCTAssertEqual(error?.code, .mediaInvalid, "\(String(describing: type))")
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        XCTAssertEqual(
            mediaThrownAPIError { _ = try self.validate(.post, png) }?.code, .mediaInvalid)
        let broken = Data([UInt8](TestJPEG.make()).dropLast(2))
        XCTAssertEqual(
            mediaThrownAPIError { _ = try self.validate(.post, broken) }?.code, .mediaInvalid)
    }

    // MARK: - Form fields

    func testFormFieldNamesMatchTheContract() {
        let form = UploadForm(
            purpose: "post", clientId: "", groupId: nil,
            file: UploadFilePart(data: ByteBuffer(), contentType: .jpeg))
        let labels = Mirror(reflecting: form).children.compactMap(\.label)
        XCTAssertEqual(
            labels,
            [
                UploadFormField.purpose, UploadFormField.clientID, UploadFormField.groupID,
                UploadFormField.file,
            ])
    }

    /// The file part keeps the type its own header declares, not one guessed from `photo.jpg`.
    func testMultipartDecodingKeepsThePartContentType() throws {
        let boundary = "test-boundary"
        let client = UUID()
        let group = UUID()
        let jpeg = TestJPEG.make()
        for (declared, expected) in [
            ("image/jpeg", HTTPMediaType.jpeg), ("image/png", .png),
        ] as [(String?, HTTPMediaType?)] + [(nil, nil)] {
            let body = mediaMultipartBody(
                boundary: boundary, purpose: "post", groupID: group, jpeg: jpeg, clientID: client,
                partContentType: declared)
            let form = try FormDataDecoder().decode(
                UploadForm.self, from: ByteBuffer(data: body), boundary: boundary)
            XCTAssertEqual(form.purpose, "post")
            XCTAssertEqual(form.clientId, client.uuidString.lowercased())
            XCTAssertEqual(form.groupId, group.uuidString.lowercased())
            XCTAssertEqual(Data(buffer: form.file.data), jpeg)
            XCTAssertEqual(form.file.contentType, expected, String(describing: declared))
        }

        let profile = mediaMultipartBody(
            boundary: boundary, purpose: "profile", groupID: nil, jpeg: jpeg, clientID: client,
            partContentType: "image/jpeg")
        let form = try FormDataDecoder().decode(
            UploadForm.self, from: ByteBuffer(data: profile), boundary: boundary)
        XCTAssertNil(form.groupId)
    }

    func testParsesFields() throws {
        let client = UUID()
        let group = UUID()
        let post = try UploadFields.parse(
            purpose: "post", clientId: client.uuidString.lowercased(),
            groupId: group.uuidString.lowercased())
        XCTAssertEqual(post, UploadFields(purpose: .post, clientID: client, groupID: group))

        // A profile photo belongs to no group, even when one is sent.
        let profile = try UploadFields.parse(
            purpose: "profile", clientId: client.uuidString, groupId: group.uuidString)
        XCTAssertNil(profile.groupID)
        XCTAssertNil(
            try UploadFields.parse(purpose: "profile", clientId: client.uuidString, groupId: nil)
                .groupID)
    }

    func testRefusesBadFields() {
        let client = UUID().uuidString
        let cases: [(String, String, String?, String)] = [
            ("avatar", client, nil, UploadFormField.purpose),
            ("POST", client, UUID().uuidString, UploadFormField.purpose),
            ("post", "not-a-uuid", UUID().uuidString, UploadFormField.clientID),
            ("sticker", client, nil, UploadFormField.groupID),
            ("comment", client, "  ", UploadFormField.groupID),
            ("post", client, "group", UploadFormField.groupID),
        ]
        for (purpose, clientID, groupID, field) in cases {
            let error = mediaThrownAPIError {
                _ = try UploadFields.parse(purpose: purpose, clientId: clientID, groupId: groupID)
            }
            XCTAssertEqual(error?.code, .validationFailed, "\(purpose) \(field)")
            XCTAssertEqual(error?.field, field)
        }
    }
}

/// Signed media file URLs (`SignedMediaFile`, `MediaURLSigner`) without a database.
final class SignedMediaFileTests: XCTestCase {
    private let signer = MediaURLSigner(
        secret: "test-media-url-secret-test-media-url", baseURL: URL(string: "https://example.org")!
    )
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func query(_ url: URL) -> (exp: String?, sig: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (
            items.first { $0.name == "exp" }?.value, items.first { $0.name == "sig" }?.value
        )
    }

    private func isAccepted(
        _ id: UUID, exp: String?, sig: String?, signer: MediaURLSigner? = nil, at date: Date? = nil
    ) -> Bool {
        do {
            try SignedMediaFile.verify(
                mediaID: id, expiry: exp, signature: sig, signer: signer ?? self.signer,
                now: date ?? now)
            return true
        } catch let error as APIError {
            XCTAssertEqual(error.code, .forbidden)
            XCTAssertEqual(error.httpStatus, 403)
            return false
        } catch {
            XCTFail("\(error)")
            return false
        }
    }

    func testIssuedURLIsAcceptedUntilItExpires() throws {
        let id = UUID()
        let issued = signer.signedURL(for: id, now: now)
        XCTAssertEqual(issued.url.path, "/api/media-files/\(id.uuidString.lowercased())")
        XCTAssertEqual(issued.expiresAt, now.addingTimeInterval(600))
        let (exp, sig) = query(issued.url)
        XCTAssertTrue(isAccepted(id, exp: exp, sig: sig))
        XCTAssertTrue(isAccepted(id, exp: exp, sig: sig, at: now.addingTimeInterval(599)))
        XCTAssertFalse(isAccepted(id, exp: exp, sig: sig, at: now.addingTimeInterval(600)))
        XCTAssertFalse(isAccepted(id, exp: exp, sig: sig, at: now.addingTimeInterval(3_600)))
    }

    func testTamperedURLsAreRefused() throws {
        let id = UUID()
        let (exp, sig) = query(signer.signedURL(for: id, now: now).url)
        let expiry = try XCTUnwrap(exp)
        let signature = try XCTUnwrap(sig)

        XCTAssertFalse(isAccepted(UUID(), exp: exp, sig: sig))
        XCTAssertFalse(isAccepted(id, exp: String(Int(expiry)! + 3_600), sig: sig))
        // The first character carries six significant bits (the last one only four).
        let flipped = (signature.first == "A" ? "B" : "A") + signature.dropFirst()
        XCTAssertFalse(isAccepted(id, exp: exp, sig: flipped))
        XCTAssertFalse(isAccepted(id, exp: exp, sig: signature + "=="))
        XCTAssertFalse(isAccepted(id, exp: nil, sig: sig))
        XCTAssertFalse(isAccepted(id, exp: exp, sig: nil))
        XCTAssertFalse(isAccepted(id, exp: "soon", sig: sig))
        XCTAssertFalse(isAccepted(id, exp: exp, sig: ""))
        let other = MediaURLSigner(
            secret: "another-secret-another-secret-another", baseURL: URL(string: "https://x")!)
        XCTAssertFalse(isAccepted(id, exp: exp, sig: sig, signer: other))
    }

    func testRefFromConfigUsesThePublicBaseURL() throws {
        let config = AppConfig.testing(databaseURL: "postgres://localhost/x", mediaRoot: "/tmp/m")
        let id = UUID()
        let media = Media(
            id: id, uploaderID: UUID(), purpose: .post, groupID: UUID(),
            filePath: MediaPaths.relativePath(for: id), byteCount: 1_234, width: 30, height: 40,
            sha256: Data(count: 32), clientID: UUID())
        let ref = try MediaURLSigner(config: config).ref(for: media, now: now)
        XCTAssertEqual(ref.id, id)
        XCTAssertEqual(ref.width, 30)
        XCTAssertEqual(ref.height, 40)
        XCTAssertEqual(ref.byteCount, 1_234)
        XCTAssertEqual(ref.urlExpiresAt, now.addingTimeInterval(MediaRef.signedURLLifetime))
        XCTAssertEqual(ref.url.host, config.publicBaseURL.host)
        let (exp, sig) = query(ref.url)
        XCTAssertTrue(isAccepted(id, exp: exp, sig: sig, signer: MediaURLSigner(config: config)))
    }

    func testFileResponseHeaders() {
        let response = SignedMediaFile.response(Data([0xFF, 0xD8]))
        XCTAssertEqual(response.headers.contentType, .jpeg)
        XCTAssertEqual(response.headers.first(name: .cacheControl), "private, max-age=600")
        XCTAssertEqual(response.headers.first(name: "X-Content-Type-Options"), "nosniff")
    }
}
