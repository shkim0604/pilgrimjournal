import Fluent
import SQLKit

/// Runs plain SQL statements one at a time (the extended query protocol refuses several
/// commands in one statement). Migrations are written as SQL because the schema needs partial
/// UNIQUE indexes, CHECK constraints, a DESC index and a trigger (design.md "Postgres 스키마").
enum SchemaSQL {
    static func run(_ statements: [String], on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            fatalError("Pilgrim migrations need an SQL database (Postgres)")
        }
        for statement in statements {
            try await sql.raw(SQLQueryString(statement)).run()
        }
    }
}
