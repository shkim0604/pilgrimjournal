import Foundation
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// `/internal/admin/v1/*` guard and the moderation pieces that need no database.
final class AdminGuardTests: ServerTestCase {
    private var token: String { app.pilgrimConfig.adminAPIToken ?? "" }

    private func adminHeaders(token: String?, actor: String? = "운영자", extra: [String: String] = [:])
        -> HTTPHeaders
    {
        var headers = HTTPHeaders()
        if let token { headers.replaceOrAdd(name: PilgrimHeader.adminToken, value: token) }
        if let actor { headers.replaceOrAdd(name: PilgrimHeader.adminActor, value: actor) }
        for (name, value) in extra { headers.replaceOrAdd(name: name, value: value) }
        return headers
    }

    func testMissingOrWrongTokenIs401() async throws {
        for candidate in [nil, "wrong", token + "x", String(token.dropLast())] {
            try await app.test(
                .GET, "internal/admin/v1/status", headers: adminHeaders(token: candidate)
            ) {
                res async throws in
                XCTAssertEqual(res.status, .unauthorized, candidate ?? "nil")
                XCTAssertEqual(try errorBody(res).code, .unauthenticated)
            }
        }
    }

    func testTunnelHeadersAre403EvenWithTheRightToken() async throws {
        for header in AdminGuardMiddleware.tunnelHeaders {
            try await app.test(
                .GET, "internal/admin/v1/status",
                headers: adminHeaders(token: token, extra: [header: "1.2.3.4"])
            ) { res async throws in
                XCTAssertEqual(res.status, .forbidden, header)
                XCTAssertEqual(try errorBody(res).code, .forbidden, header)
            }
        }
    }

    func testTunnelHeaderIsRefusedBeforeTheTokenIsChecked() async throws {
        try await app.test(
            .GET, "internal/admin/v1/reports",
            headers: adminHeaders(token: nil, extra: ["Cf-Ray": "x"])
        ) { res async throws in
            XCTAssertEqual(res.status, .forbidden)
        }
    }

    func testActionsRequireAnActor() async throws {
        for actor in [nil, "   ", String(repeating: "a", count: 101)] {
            try await app.test(
                .DELETE, "internal/admin/v1/posts/\(UUID())",
                headers: adminHeaders(token: token, actor: actor)
            ) { res async throws in
                XCTAssertEqual(res.status, .badRequest, actor ?? "nil")
                XCTAssertEqual(try errorBody(res).code, .invalidRequest)
            }
        }
    }

    func testMalformedIDIs404() async throws {
        try await app.test(
            .DELETE, "internal/admin/v1/posts/not-a-uuid", headers: adminHeaders(token: token)
        ) { res async throws in
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testAdminRoutesNeedNoClientHeader() async throws {
        // No X-Pilgrim-Client: the guard answers (401), not the client gate (426).
        try await app.test(.GET, "internal/admin/v1/status") { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testModerationRoutesNeedAnAccessToken() async throws {
        for (method, path) in [
            (HTTPMethod.GET, "api/v1/me/blocks"), (.PUT, "api/v1/me/blocks/\(UUID())"),
            (.GET, "api/v1/me/hides"), (.PUT, "api/v1/me/hides/posts/\(UUID())"),
            (.DELETE, "api/v1/me/hides/users/\(UUID())"), (.POST, "api/v1/reports"),
        ] {
            try await app.test(method, path, headers: try headers()) { res async throws in
                XCTAssertEqual(res.status, .unauthorized, path)
            }
        }
    }

    // MARK: - Pure helpers

    func testTokenComparison() {
        XCTAssertTrue(AdminGuardMiddleware.tokensMatch("abc", "abc"))
        XCTAssertFalse(AdminGuardMiddleware.tokensMatch("abc", "abd"))
        XCTAssertFalse(AdminGuardMiddleware.tokensMatch("abc", "abcd"))
        XCTAssertFalse(AdminGuardMiddleware.tokensMatch("", "abc"))
    }

    func testWebhookSummaryCarriesOnlyReasonAndType() throws {
        let summary = ReportWebhookSummary(reason: .harassment, targetType: .comment)
        XCTAssertEqual(summary.text, "새 신고 harassment (comment)")
        XCTAssertEqual(summary.payload, ["text": "새 신고 harassment (comment)"])
    }

    func testReportNoteValidation() throws {
        XCTAssertNil(try ModerationService.validatedNote(nil))
        XCTAssertNil(try ModerationService.validatedNote("  \n "))
        XCTAssertEqual(try ModerationService.validatedNote("  욕설  "), "욕설")
        let limit = String(repeating: "가", count: APILimits.reportNoteMax)
        XCTAssertEqual(try ModerationService.validatedNote(limit), limit)
        XCTAssertThrowsError(try ModerationService.validatedNote(limit + "가")) { error in
            XCTAssertEqual((error as? APIError)?.code, .limitExceeded)
        }
    }

    func testAccountGate() throws {
        let now = Date()
        XCTAssertThrowsError(try ModerationAccountGate.check(nil, now: now)) {
            XCTAssertEqual(($0 as? APIError)?.code, .unauthenticated)
        }
        let unnamed = User(appleSub: "dev:a", displayName: nil, timeZone: "Asia/Seoul")
        XCTAssertThrowsError(try ModerationAccountGate.check(unnamed, now: now)) {
            XCTAssertEqual(($0 as? APIError)?.code, .signupRequired)
        }
        let user = User(appleSub: "dev:b", displayName: "이름", timeZone: "Asia/Seoul")
        XCTAssertNoThrow(try ModerationAccountGate.check(user, now: now))

        user.suspendedAt = now.addingTimeInterval(-60)
        XCTAssertThrowsError(try ModerationAccountGate.check(user, now: now)) {
            XCTAssertEqual(($0 as? APIError)?.code, .accountSuspended)
        }
        XCTAssertEqual(ModerationPresenter.suspendedUntil(user, now: now), .distantFuture)

        user.suspendedUntil = now.addingTimeInterval(3_600)
        XCTAssertEqual(ModerationPresenter.suspendedUntil(user, now: now), user.suspendedUntil)

        user.suspendedUntil = now.addingTimeInterval(-1)
        XCTAssertNoThrow(try ModerationAccountGate.check(user, now: now))
        XCTAssertNil(ModerationPresenter.suspendedUntil(user, now: now))
    }
}

/// Without `ADMIN_API_TOKEN` the operator routes do not exist.
final class AdminGuardDisabledTests: ServerTestCase {
    override func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        var config = AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot)
        config.adminAPIToken = nil
        return config
    }

    func testRoutesAre404() async throws {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: PilgrimHeader.adminToken, value: "anything")
        try await app.test(.GET, "internal/admin/v1/status", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .notFound)
            XCTAssertEqual(try errorBody(res).code, .notFound)
        }
    }
}
