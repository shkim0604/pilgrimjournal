import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor
import XCTVapor

@testable import PilgrimServerCore

/// Base class for server tests.
///
/// - `DatabaseTestCase` subclasses talk to a real Postgres at `TEST_DATABASE_URL`
///   (`make -C server test` starts one in Docker and sets it). The schema is dropped and
///   migrated once per test process, and every table is truncated before each test. Without
///   `TEST_DATABASE_URL` those tests are skipped with a message.
/// - Plain `ServerTestCase` builds the same app against an unreachable database, for routes and
///   middleware that never touch Postgres.
///
/// Tests run serially (do not pass `--parallel`): they share one test database.
class ServerTestCase: XCTestCase {
    var app: Application!
    var mediaRoot: URL!

    /// Override to change settings before `configure` (for example `dayLength`).
    func makeConfig(databaseURL: String, mediaRoot: String) -> AppConfig {
        AppConfig.testing(databaseURL: databaseURL, mediaRoot: mediaRoot)
    }

    /// The database URL this case uses. Subclasses that need Postgres return the test database.
    func databaseURL() throws -> String {
        // Nothing listens on port 1, so any accidental query fails fast.
        "postgres://pilgrim:pilgrim@127.0.0.1:1/unreachable?sslmode=disable"
    }

    override func setUp() async throws {
        try await super.setUp()
        let url = try databaseURL()
        mediaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilgrim-media-\(UUID().uuidString)", isDirectory: true)
        app = try await Application.make(.testing)
        do {
            try await configure(
                app, config: makeConfig(databaseURL: url, mediaRoot: mediaRoot.path))
            app.accessTokenVerifier = TestAccessTokens()
            try await prepareDatabase()
        } catch {
            try? await app.asyncShutdown()
            app = nil
            throw error
        }
    }

    override func tearDown() async throws {
        if let app {
            try await app.asyncShutdown()
        }
        app = nil
        if let mediaRoot {
            try? FileManager.default.removeItem(at: mediaRoot)
        }
        try await super.tearDown()
    }

    func prepareDatabase() async throws {}

    var db: any Database { app.db }

    var sql: any SQLDatabase { app.db as! any SQLDatabase }

    // MARK: - Request helpers

    /// A valid `X-Pilgrim-Client` for the Release bundle.
    static let clientHeaderValue = "ios/1.3.0 (31) \(BundleIDs.release)"

    /// Client header plus, when `user` is given, a bearer token `TestAccessTokens` accepts.
    func headers(as user: User? = nil) throws -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: ClientHeader.name, value: Self.clientHeaderValue)
        if let user {
            headers.bearerAuthorization = BearerAuthorization(
                token: TestAccessTokens.token(for: try user.requireID()))
        }
        return headers
    }

    func decode<T: Decodable>(_ type: T.Type, from response: XCTHTTPResponse) throws -> T {
        try PilgrimJSON.decode(type, from: Data(buffer: response.body))
    }

    func errorBody(_ response: XCTHTTPResponse) throws -> APIError {
        try decode(APIErrorBody.self, from: response).error
    }
}

/// A `ServerTestCase` backed by the Postgres test database.
class DatabaseTestCase: ServerTestCase {
    override func databaseURL() throws -> String {
        try TestDatabase.url()
    }

    override func prepareDatabase() async throws {
        try await TestDatabase.prepare(app)
    }

    var fixtures: TestFixtures { TestFixtures(db: app.db) }
}

/// Accepts `test-user:<uuid>` bearer tokens, standing in for S1's JWT verifier in tests.
struct TestAccessTokens: AccessTokenVerifying {
    static func token(for userID: UUID) -> String { "test-user:\(userID.uuidString)" }

    func verify(_ token: String, for request: Request) async throws -> AuthenticatedUser {
        guard token.hasPrefix("test-user:"),
            let id = UUID(uuidString: String(token.dropFirst("test-user:".count)))
        else { throw APIError.unauthenticated("invalid test token") }
        return AuthenticatedUser(id: id)
    }
}
