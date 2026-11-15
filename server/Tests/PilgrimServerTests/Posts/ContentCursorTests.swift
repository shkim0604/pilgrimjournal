import Foundation
import PilgrimAPI
import Vapor
import XCTest

@testable import PilgrimServerCore

/// Cursors, page parameters and unread cut-offs (no database).
final class ContentCursorTests: XCTestCase {
    func testCursorRoundTripsAtMicrosecondPrecision() throws {
        let id = UUID()
        let cursor = ContentCursor(
            createdAt: Date(timeIntervalSince1970: 1_794_625_200.123457), id: id)
        XCTAssertEqual(cursor.microseconds, 1_794_625_200_123_457)
        let decoded = try XCTUnwrap(ContentCursor(encoded: cursor.encoded))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.microseconds, cursor.microseconds)
        // base64url: no padding or characters that need escaping in a query.
        XCTAssertNil(cursor.encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testForeignCursorsAreRejected() {
        for text in [
            "nope", Data("123".utf8).base64URLEncodedString(),
            Data("-5.\(UUID().uuidString)".utf8).base64URLEncodedString(),
            Data("12.not-a-uuid".utf8).base64URLEncodedString(),
        ] {
            XCTAssertNil(ContentCursor(encoded: text), text)
            XCTAssertThrowsError(try PageRequest.parse(cursor: text, limit: nil)) {
                XCTAssertEqual(($0 as? APIError)?.code, .invalidRequest)
            }
        }
    }

    func testLimitDefaultsAndClamps() throws {
        XCTAssertEqual(try PageRequest.parse(cursor: nil, limit: nil).limit, 20)
        XCTAssertEqual(try PageRequest.parse(cursor: "", limit: "").limit, 20)
        XCTAssertEqual(try PageRequest.parse(cursor: nil, limit: "5").limit, 5)
        XCTAssertEqual(try PageRequest.parse(cursor: nil, limit: "500").limit, 50)
        for bad in ["0", "-1", "ten"] {
            XCTAssertThrowsError(try PageRequest.parse(cursor: nil, limit: bad), bad)
        }
    }

    func testSplitReturnsNextCursorOnlyWhenMoreRowsFollow() {
        let request = PageRequest(limit: 2)
        XCTAssertEqual(request.fetchLimit, 3)
        let ids = (0..<3).map { _ in UUID() }
        let at = Date(timeIntervalSince1970: 1_000)
        let cursor = { (id: UUID) in ContentCursor(createdAt: at, id: id) }

        let full = request.split(ids, cursor: cursor)
        XCTAssertEqual(full.rows, Array(ids.prefix(2)))
        XCTAssertEqual(full.nextCursor, cursor(ids[1]).encoded)

        let last = request.split(Array(ids.prefix(2)), cursor: cursor)
        XCTAssertEqual(last.rows.count, 2)
        XCTAssertNil(last.nextCursor)
    }

    func testUnreadCutoffPrefersLastSeen() {
        let joined = Date(timeIntervalSince1970: 100)
        let seen = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(PostUnread.cutoff(lastSeenAt: nil, joinedAt: joined), joined)
        XCTAssertEqual(PostUnread.cutoff(lastSeenAt: seen, joinedAt: joined), seen)
    }
}

/// The posts routes exist behind the shared authentication (no database needed to see 401s).
final class PostRoutesAuthTests: ServerTestCase {
    func testEveryRouteNeedsASignedInUser() async throws {
        let id = UUID().uuidString.lowercased()
        let routes: [(HTTPMethod, String)] = [
            (.GET, "groups/\(id)/posts"), (.POST, "groups/\(id)/posts"), (.GET, "posts/\(id)"),
            (.DELETE, "posts/\(id)"), (.POST, "posts/\(id)/extend"),
            (.GET, "posts/\(id)/comments"), (.POST, "posts/\(id)/comments"),
            (.DELETE, "comments/\(id)"), (.PUT, "posts/\(id)/reactions"),
            (.DELETE, "posts/\(id)/reactions?emoji=%F0%9F%99%8F"),
        ]
        for (method, path) in routes {
            let response = try await send(method, path, as: nil)
            try assertError(response, 401, .unauthenticated)
        }
    }
}
