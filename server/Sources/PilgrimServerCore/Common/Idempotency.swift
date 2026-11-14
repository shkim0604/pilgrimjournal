import Fluent
import FluentPostgresDriver
import Foundation
import PilgrimAPI
import Vapor

/// `clientId` idempotency for creating writes (design.md 2절 "멱등성"): the first request with a
/// `clientId` creates the resource (201), a repeat returns the first resource unchanged (200),
/// even if the body differs. Every such table has `UNIQUE(<author>, client_id)`.
public enum Idempotency {
    public struct Outcome<Value: Sendable>: Sendable {
        public var value: Value
        /// false when an earlier request with the same `clientId` already created it.
        public var created: Bool

        /// 201 for a new resource, 200 for a repeat.
        public var status: HTTPResponseStatus { created ? .created : .ok }
    }

    /// Returns the existing resource for this `clientId`, or creates it.
    ///
    /// - `existing` looks the resource up by `(author, clientId)`.
    /// - `create` inserts it (and anything else that belongs to the same write). It runs in a
    ///   transaction; when a concurrent request wins the unique key, the transaction rolls back
    ///   and `existing` is asked again.
    public static func findOrCreate<Value: Sendable>(
        on db: any Database,
        existing: @escaping @Sendable (any Database) async throws -> Value?,
        create: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Outcome<Value> {
        if let found = try await existing(db) {
            return Outcome(value: found, created: false)
        }
        do {
            let value = try await db.transaction { try await create($0) }
            return Outcome(value: value, created: true)
        } catch let error where isUniqueViolation(error) {
            if let found = try await existing(db) {
                return Outcome(value: found, created: false)
            }
            throw error
        }
    }

    /// Whether `error` is a Postgres unique-constraint violation (SQLSTATE 23505).
    public static func isUniqueViolation(_ error: any Error) -> Bool {
        sqlState(of: error) == "23505"
    }

    /// Whether `error` is a CHECK violation (SQLSTATE 23514).
    public static func isCheckViolation(_ error: any Error) -> Bool {
        sqlState(of: error) == "23514"
    }

    static func sqlState(of error: any Error) -> String? {
        if let error = error as? PSQLError {
            return error.serverInfo?[.sqlState]
        }
        return nil
    }
}

extension Response {
    /// Encodes `value` with `PilgrimJSON` and the given status (201 / 200 for idempotent writes).
    public static func pilgrimJSON(_ value: some Encodable, status: HTTPResponseStatus = .ok)
        throws -> Response
    {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(
            status: status, headers: headers, body: .init(data: try PilgrimJSON.encode(value)))
    }
}
