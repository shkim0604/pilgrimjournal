import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

/// Identity token checks against a fake JWKS (no database, no network).
final class AppleIdentityTokenTests: XCTestCase {
    private var source: FakeJWKSSource!
    private var verifier: AppleIdentityTokenVerifier!

    override func setUp() async throws {
        try await super.setUp()
        source = FakeJWKSSource()
        verifier = AppleIdentityTokenVerifier(cache: AppleJWKSCache(source: source))
    }

    private func verify(_ token: String, bundleID: String = BundleIDs.release) async throws
        -> AppleIdentity
    {
        try await verifier.verify(
            identityToken: token, bundleID: bundleID, rawNonce: AppleTestTokens.rawNonce)
    }

    private func assertFails(
        _ code: APIErrorCode, bundleID: String = BundleIDs.release, file: StaticString = #filePath,
        line: UInt = #line, _ token: () throws -> String
    ) async throws {
        let token = try token()
        do {
            _ = try await verify(token, bundleID: bundleID)
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as APIError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        }
    }

    func testValidTokenForEitherBundle() async throws {
        for bundle in [BundleIDs.release, BundleIDs.debug] {
            let identity = try await verify(
                try AppleTestTokens.token(sub: "user-\(bundle)", aud: bundle), bundleID: bundle)
            XCTAssertEqual(identity.subject, "user-\(bundle)")
            XCTAssertEqual(identity.bundleID, bundle)
        }
    }

    func testNonceHashIsLowercaseHexSHA256() {
        // printf 'abc' | shasum -a 256
        XCTAssertEqual(
            AppleIdentityTokenVerifier.nonceHash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testNonceMismatch() async throws {
        try await assertFails(.appleNonceMismatch) {
            try AppleTestTokens.token(nonce: AppleIdentityTokenVerifier.nonceHash("other"))
        }
        try await assertFails(.appleNonceMismatch) { try AppleTestTokens.token(nonce: nil) }
    }

    func testWrongAudienceIssuerAndExpiry() async throws {
        try await assertFails(.appleTokenInvalid) {
            try AppleTestTokens.token(aud: BundleIDs.debug)
        }
        try await assertFails(.appleTokenInvalid) {
            try AppleTestTokens.token(iss: "https://example.com")
        }
        try await assertFails(.appleTokenInvalid) {
            try AppleTestTokens.token(expiresIn: -60)
        }
    }

    func testUnknownBundleIsInvalidRequest() async throws {
        try await assertFails(.invalidRequest, bundleID: "com.example.other") {
            try AppleTestTokens.token(aud: "com.example.other")
        }
    }

    func testForgedSignatureAndGarbage() async throws {
        // Claims a known kid but is signed with the other key.
        try await assertFails(.appleTokenInvalid) {
            try AppleTestTokens.token(
                kid: AppleTestKeys.firstKID, signingKeyPEM: AppleTestKeys.secondPrivateKeyPEM)
        }
        try await assertFails(.appleTokenInvalid) { "not-a-jwt" }
    }

    func testCacheIsReusedForKnownKid() async throws {
        _ = try await verify(try AppleTestTokens.token())
        _ = try await verify(try AppleTestTokens.token())
        let count = await source.fetchCount
        XCTAssertEqual(count, 1)
    }

    func testUnknownKidRefetchesOnce() async throws {
        _ = try await verify(try AppleTestTokens.token())
        // Apple rotates: the second key appears only in a fresh JWKS.
        await source.publish(kids: [AppleTestKeys.firstKID, AppleTestKeys.secondKID])
        let identity = try await verify(try AppleTestTokens.token(kid: AppleTestKeys.secondKID))
        XCTAssertEqual(identity.subject, "001234.apple-test-user")
        let count = await source.fetchCount
        XCTAssertEqual(count, 2)
    }

    func testUnknownKidRefetchIsThrottled() async throws {
        _ = try await verify(try AppleTestTokens.token())
        for _ in 0..<3 {
            try await assertFails(.appleTokenInvalid) {
                try AppleTestTokens.token(kid: "never-published")
            }
        }
        // One initial fetch plus at most one refetch inside the 10-second window.
        let count = await source.fetchCount
        XCTAssertEqual(count, 2)
    }

    func testStaleCacheIsRefetched() async throws {
        let cache = AppleJWKSCache(source: source, maxAge: 3_600)
        let now = Date()
        _ = try await cache.jwks(containing: AppleTestKeys.firstKID, now: now)
        _ = try await cache.jwks(
            containing: AppleTestKeys.firstKID, now: now.addingTimeInterval(1_800))
        _ = try await cache.jwks(
            containing: AppleTestKeys.firstKID, now: now.addingTimeInterval(3_601))
        let count = await source.fetchCount
        XCTAssertEqual(count, 2)
    }
}
