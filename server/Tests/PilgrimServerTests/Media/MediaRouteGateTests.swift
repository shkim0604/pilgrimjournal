import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// What the Media and Stickers routes refuse before they touch the database (runs without
/// Postgres).
final class MediaRouteGateTests: ServerTestCase {
    private var signer: MediaURLSigner { MediaURLSigner(config: app.pilgrimConfig) }

    func testSignedFileRouteRefusesBadSignaturesWithoutTheClientHeader() async throws {
        let id = UUID()
        let base = "/api/media-files/\(id.uuidString.lowercased())"
        let issued = signer.signedURL(for: id)
        let query = try XCTUnwrap(issued.url.query)
        let expired = signer.signedURL(for: id, now: Date().addingTimeInterval(-3_600))
        let otherID = signer.signedURL(for: UUID())

        for target in [
            base,
            "\(base)?exp=\(Int(Date().timeIntervalSince1970) + 600)",
            "\(base)?sig=abc",
            "\(base)?\(try XCTUnwrap(expired.url.query))",
            "\(base)?\(try XCTUnwrap(otherID.url.query))",
            "\(base)?\(query.replacingOccurrences(of: "sig=", with: "sig=x"))",
        ] {
            let response = try await mediaFetch(URL(string: "http://localhost\(target)")!)
            XCTAssertEqual(response.status, .forbidden, target)
            XCTAssertEqual(try errorBody(response).code, .forbidden, target)
        }
    }

    func testSignedFileRouteAnswers404ForAMalformedID() async throws {
        let response = try await mediaFetch(
            URL(string: "http://localhost/api/media-files/not-a-uuid?exp=1&sig=a")!)
        XCTAssertEqual(response.status, .notFound)
    }

    func testRoutesNeedASignedInUser() async throws {
        let id = UUID()
        let upload = try await mediaUpload(
            "post", groupID: UUID(), as: nil, jpeg: TestJPEG.make())
        XCTAssertEqual(upload.status, .unauthorized)
        for (method, path) in [
            (HTTPMethod.GET, "media/\(id)"), (.GET, "groups/\(id)/stickers"),
            (.POST, "groups/\(id)/stickers"), (.DELETE, "stickers/\(id)"),
        ] {
            let response = try await sendV1(method, path, as: nil)
            XCTAssertEqual(response.status, .unauthorized, "\(method) \(path)")
            XCTAssertEqual(try errorBody(response).code, .unauthenticated)
        }
    }

    func testV1RoutesNeedTheClientHeader() async throws {
        let request = XCTHTTPRequest(
            method: .GET, url: URI(string: "/api/v1/media/\(UUID())"), headers: HTTPHeaders(),
            body: ByteBufferAllocator().buffer(capacity: 0))
        let response = try await app.testable().performTest(request: request)
        XCTAssertEqual(try errorBody(response).code, .clientUpgradeRequired)
    }
}
