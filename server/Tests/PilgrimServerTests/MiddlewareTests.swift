import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Client gate, error envelope, auth stub and rate limits — no database needed.
final class MiddlewareTests: ServerTestCase {
    override func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        var config = AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot)
        config.minimumClientVersion = ClientVersion("1.3.0")
        return config
    }

    override func setUp() async throws {
        try await super.setUp()
        let routes = app.pilgrimRoutes
        routes.v1.get("test", "open") { _ in "open" }
        routes.authenticated.get("test", "me") { req in try req.userID.uuidString }
        routes.authenticated.get("test", "conflict") { _ -> String in
            throw APIError(code: .inviteFull, message: "full")
        }
        routes.authenticated.get("test", "crash") { _ -> String in
            struct Boom: Error {}
            throw Boom()
        }
    }

    private func client(_ value: String?) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let value { headers.replaceOrAdd(name: ClientHeader.name, value: value) }
        return headers
    }

    func testMissingClientHeaderIs426() async throws {
        try await app.test(.GET, "api/v1/test/open") { res async throws in
            XCTAssertEqual(res.status.code, 426)
            XCTAssertEqual(try errorBody(res).code, .clientUpgradeRequired)
            XCTAssertEqual(res.headers.contentType, .json)
        }
    }

    func testMalformedAndOldClientsAre426() async throws {
        for value in ["garbage", "ios/1.2.9 (30) com.dhouse.PilgrimJournal"] {
            try await app.test(.GET, "api/v1/test/open", headers: client(value)) {
                res async throws in
                XCTAssertEqual(res.status.code, 426, value)
                XCTAssertEqual(try errorBody(res).code, .clientUpgradeRequired, value)
            }
        }
    }

    func testUnknownBundleIs400() async throws {
        try await app.test(
            .GET, "api/v1/test/open", headers: client("ios/1.3.0 (31) com.example.app")
        ) { res async throws in
            XCTAssertEqual(res.status.code, 400)
            XCTAssertEqual(try errorBody(res).code, .invalidRequest)
        }
    }

    func testBothBundlesAndCurrentVersionPass() async throws {
        for bundle in BundleIDs.all {
            try await app.test(
                .GET, "api/v1/test/open", headers: client("macos/1.3 (40) \(bundle)")
            ) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "open")
            }
        }
    }

    func testAuthenticatedRoutesNeedABearerToken() async throws {
        try await app.test(.GET, "api/v1/test/me", headers: try headers()) { res async throws in
            XCTAssertEqual(res.status.code, 401)
            XCTAssertEqual(try errorBody(res).code, .unauthenticated)
        }
        let userID = UUID()
        var headers = try headers()
        headers.bearerAuthorization = BearerAuthorization(
            token: TestAccessTokens.token(for: userID))
        try await app.test(.GET, "api/v1/test/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, userID.uuidString)
        }
    }

    func testDefaultVerifierRefusesEveryToken() async throws {
        app.accessTokenVerifier = RejectingAccessTokenVerifier()
        var headers = try headers()
        headers.bearerAuthorization = BearerAuthorization(
            token: TestAccessTokens.token(for: UUID()))
        try await app.test(.GET, "api/v1/test/me", headers: headers) { res async throws in
            XCTAssertEqual(res.status.code, 401)
        }
    }

    func testAPIErrorsUseTheEnvelopeAndStatus() async throws {
        var headers = try headers()
        headers.bearerAuthorization = BearerAuthorization(
            token: TestAccessTokens.token(for: UUID()))
        try await app.test(.GET, "api/v1/test/conflict", headers: headers) { res async throws in
            XCTAssertEqual(res.status.code, 409)
            let error = try errorBody(res)
            XCTAssertEqual(error, APIError(code: .inviteFull, message: "full"))
        }
        try await app.test(.GET, "api/v1/test/crash", headers: headers) { res async throws in
            XCTAssertEqual(res.status.code, 500)
            XCTAssertEqual(try errorBody(res).code, .internal)
        }
    }

    func testUnknownRouteIsEnvelope404() async throws {
        try await app.test(.GET, "api/v1/nothing-here", headers: try headers()) {
            res async throws in
            XCTAssertEqual(res.status.code, 404)
            XCTAssertEqual(try errorBody(res).code, .notFound)
        }
    }

    func testUnauthenticatedRoutesAreLimitedPerIP() async throws {
        app.pilgrimConfig.rateLimits.unauthenticatedPerIP = RateLimitRule(requests: 2, window: 600)
        var headers = try headers()
        headers.replaceOrAdd(name: "Cf-Connecting-IP", value: "203.0.113.7")
        for _ in 0..<2 {
            try await app.test(.GET, "api/v1/test/open", headers: headers) { res async throws in
                XCTAssertEqual(res.status, .ok)
            }
        }
        try await app.test(.GET, "api/v1/test/open", headers: headers) { res async throws in
            XCTAssertEqual(res.status.code, 429)
            let error = try errorBody(res)
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertEqual(res.headers.first(name: .retryAfter), error.retryAfter.map(String.init))
            XCTAssertGreaterThan(error.retryAfter ?? 0, 0)
        }
        headers.replaceOrAdd(name: "Cf-Connecting-IP", value: "203.0.113.8")
        try await app.test(.GET, "api/v1/test/open", headers: headers) { res async throws in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testHealthWithoutDatabaseIs503() async throws {
        try await app.test(.GET, "api/health") { res async throws in
            XCTAssertEqual(res.status.code, 503)
            let health = try decode(HealthResponse.self, from: res)
            XCTAssertEqual(health.status, .degraded)
            XCTAssertFalse(health.database)
            XCTAssertFalse(health.worker.healthy)
            XCTAssertEqual(health.version, "test")
        }
    }

    func testEveryModuleRegisteredAndWorkerHeartbeatJobExists() {
        XCTAssertEqual(app.workerJobs.names, ["worker"])
        XCTAssertNotNil(app.asyncCommands.commands["worker"])
    }
}
