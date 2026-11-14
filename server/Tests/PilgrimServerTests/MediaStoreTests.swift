import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

final class MediaStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilgrim-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testWriteReadDelete() async throws {
        let store = LocalDiskMediaStore(root: root)
        let id = UUID()
        let path = MediaPaths.relativePath(for: id)
        XCTAssertEqual(
            path, "\(id.uuidString.lowercased().prefix(2))/\(id.uuidString.lowercased()).jpg")

        try await store.write(Data([0xFF, 0xD8, 0xFF]), to: path)
        let exists = await store.exists(path)
        XCTAssertTrue(exists)
        let data = try await store.read(path)
        XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF]))

        try await store.delete(path)
        let existsAfterDelete = await store.exists(path)
        XCTAssertFalse(existsAfterDelete)
        // Deleting a missing file succeeds (the worker may retry).
        try await store.delete(path)
        let missing = try await store.read(path)
        XCTAssertNil(missing)
    }

    func testPathsCannotEscapeTheRoot() async {
        let store = LocalDiskMediaStore(root: root)
        for path in ["../etc/passwd", "/etc/passwd", "ab/../../x.jpg", "", "ab//x.jpg", "a b.jpg"] {
            XCTAssertThrowsError(try store.fileURL(for: path), path)
        }
    }

    func testRelativeRootResolvesAgainstTheWorkingDirectory() {
        let store = LocalDiskMediaStore(rootPath: "./.media")
        XCTAssertTrue(store.root.path.hasSuffix("/.media"))
        XCTAssertTrue(store.root.path.hasPrefix("/"))
    }
}

final class MediaURLSignerTests: XCTestCase {
    private let signer = MediaURLSigner(
        secret: "secret-secret-secret-secret-secret", baseURL: URL(string: "https://p.example")!)

    func testSignedURLShapeAndValidation() throws {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (url, expiresAt) = signer.signedURL(for: id, now: now)
        XCTAssertEqual(expiresAt, now.addingTimeInterval(600))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "p.example")
        XCTAssertEqual(components.path, "/api/media-files/\(id.uuidString.lowercased())")
        let exp = try XCTUnwrap(components.queryItems?.first { $0.name == "exp" }?.value)
        let sig = try XCTUnwrap(components.queryItems?.first { $0.name == "sig" }?.value)
        XCTAssertFalse(sig.contains("="))
        XCTAssertTrue(
            signer.isValid(mediaID: id, expiry: Int(exp)!, signature: sig, now: now))
        // Expired, other ID, other expiry, tampered signature, other secret.
        XCTAssertFalse(
            signer.isValid(
                mediaID: id, expiry: Int(exp)!, signature: sig, now: now.addingTimeInterval(601)))
        XCTAssertFalse(signer.isValid(mediaID: UUID(), expiry: Int(exp)!, signature: sig, now: now))
        XCTAssertFalse(
            signer.isValid(mediaID: id, expiry: Int(exp)! + 1, signature: sig, now: now))
        XCTAssertFalse(signer.isValid(mediaID: id, expiry: Int(exp)!, signature: "AAAA", now: now))
        let other = MediaURLSigner(
            secret: "another-secret-another-secret-0000", baseURL: URL(string: "https://p.example")!
        )
        XCTAssertFalse(other.isValid(mediaID: id, expiry: Int(exp)!, signature: sig, now: now))
    }

    func testBase64URLRoundTrip() {
        let data = Data((0..<64).map { UInt8($0 * 4 % 256) })
        let text = data.base64URLEncodedString()
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: text), data)
        XCTAssertNil(Data(base64URLEncoded: "abc="))
    }
}

final class RateLimiterTests: XCTestCase {
    func testBucketEmptiesAndRefills() async throws {
        let limiter = RateLimiter()
        let rule = RateLimitRule(requests: 2, window: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        try await limiter.consume(bucket: "b", key: "k", rule: rule, now: start)
        try await limiter.consume(bucket: "b", key: "k", rule: rule, now: start)
        do {
            try await limiter.consume(bucket: "b", key: "k", rule: rule, now: start)
            XCTFail("expected rate limit")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertEqual(error.retryAfter, 30)
        }
        // Another key has its own bucket.
        try await limiter.consume(bucket: "b", key: "other", rule: rule, now: start)
        // 30 seconds refill one token.
        try await limiter.consume(bucket: "b", key: "k", rule: rule, now: start + 30)
    }
}
