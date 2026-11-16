import Foundation
import PilgrimAPI
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// AASA and the `/i/:code` page (design.md 6절). Neither touches the database, so these run
/// without Postgres.
final class WebModuleTests: ServerTestCase {
    func testAppSiteAssociationListsBothApps() async throws {
        // No client header: AASA is outside the `/api/v1` gate.
        let response = try await app.sendRequest(.GET, ".well-known/apple-app-site-association")
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers.contentType, .json)

        struct AASA: Decodable {
            struct AppLinks: Decodable { var details: [Detail] }
            struct Detail: Decodable {
                var appIDs: [String]
                var components: [[String: String]]
            }
            var applinks: AppLinks
        }
        let aasa = try JSONDecoder().decode(AASA.self, from: Data(buffer: response.body))
        let detail = try XCTUnwrap(aasa.applinks.details.first)
        XCTAssertEqual(
            detail.appIDs,
            ["7JZU3246YR.com.dhouse.PilgrimJournal", "7JZU3246YR.com.dhouse.PilgrimJournal.debug"])
        XCTAssertEqual(detail.components, [["/": "/i/*", "comment": "group invites"]])
    }

    func testInvitePageShowsTheCodeAndNothingElse() async throws {
        let code = InviteCode.generate()
        let response = try await app.sendRequest(.GET, "i/\(code.rawValue.lowercased())")
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.headers.contentType, .html)
        XCTAssertEqual(response.headers.first(name: "X-Robots-Tag"), "noindex")
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
        let html = response.body.string
        XCTAssertTrue(html.contains(code.grouped))
        XCTAssertTrue(html.contains("Pilgrim 앱에서 열기"))
        XCTAssertTrue(html.contains("Open in Pilgrim"))
        XCTAssertTrue(html.contains("http://localhost:3100/i/\(code.rawValue)"))
    }

    func testInvitePageIsTheSameForMalformedCodesAndEscapesThem() async throws {
        let response = try await app.sendRequest(.GET, "i/%3Cscript%3E")
        XCTAssertEqual(response.status, .ok)
        let html = response.body.string
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertEqual(
            WebModule.escapeHTML(#"<a href="x">'&'</a>"#),
            "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
    }

    func testGroupRoutesNeedSignIn() async throws {
        let response = try await app.sendRequest(.GET, "api/v1/groups", headers: try headers())
        XCTAssertEqual(response.status, .unauthorized)
    }

    func testMemberCursorRoundTrips() throws {
        let cursor = MemberCursor(joinedAtMicros: 1_731_590_000_123_456, userID: UUID())
        XCTAssertEqual(try MemberCursor(encoded: cursor.encoded), cursor)
        XCTAssertThrowsError(try MemberCursor(encoded: "not a cursor"))
        XCTAssertThrowsError(
            try MemberCursor(encoded: Data("12|nope".utf8).base64URLEncodedString()))
    }

    func testSeededGeneratorIsDeterministic() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        XCTAssertEqual((0..<5).map { _ in a.next() }, (0..<5).map { _ in b.next() })
    }
}
