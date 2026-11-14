import Fluent
import Foundation
import SQLKit
import Vapor
import XCTest

@testable import PilgrimServerCore

/// The Postgres used by `DatabaseTestCase`.
enum TestDatabase {
    static let environmentKey = "TEST_DATABASE_URL"

    /// `TEST_DATABASE_URL`, or a skip that says how to get one.
    ///
    /// The database name must contain `test`: the harness drops and recreates the `public` schema,
    /// so it refuses to run against anything that looks like real data.
    static func url() throws -> String {
        guard let url = ProcessInfo.processInfo.environment[environmentKey], !url.isEmpty else {
            throw XCTSkip(
                """
                \(environmentKey) is not set; skipping Postgres tests. Run `make -C server test` \
                (starts postgres:17 in Docker) or set \(environmentKey)=postgres://…/pilgrim_test.
                """)
        }
        let databaseName =
            URLComponents(string: url)?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? ""
        guard databaseName.lowercased().contains("test") else {
            XCTFail(
                "\(environmentKey) must name a database containing 'test' (got '\(databaseName)')")
            throw XCTSkip("refusing to reset a non-test database")
        }
        return url
    }

    private static let state = MigrationState()

    /// First call in the process: drop and recreate the schema, run every migration. Every call:
    /// truncate all tables.
    static func prepare(_ app: Application) async throws {
        try await state.migrateOnce(app)
        try await truncateAll(on: app.db)
    }

    static func truncateAll(on db: any Database) async throws {
        let sql = db as! any SQLDatabase
        let tables = PilgrimMigrations.tables.map { "\"\($0)\"" }.joined(separator: ", ")
        try await sql.raw("TRUNCATE \(unsafeRaw: tables) RESTART IDENTITY CASCADE").run()
    }

    private actor MigrationState {
        var migrated = false

        func migrateOnce(_ app: Application) async throws {
            guard !migrated else { return }
            let sql = app.db as! any SQLDatabase
            try await sql.raw("DROP SCHEMA IF EXISTS public CASCADE").run()
            try await sql.raw("CREATE SCHEMA public").run()
            try await app.autoMigrate()
            migrated = true
        }
    }
}
