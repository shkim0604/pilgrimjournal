import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// The opaque `cursor` of the post feed and comment pages (design.md 2절 "페이징"): the last
/// item's `(createdAt, id)`, as `<microseconds since 1970>.<uuid>` in base64url.
///
/// Microseconds are what Postgres keeps in `timestamptz`, so a cursor built from a row read back
/// from the database compares exactly with the stored value.
struct ContentCursor: Equatable, Sendable {
    var createdAt: Date
    var id: UUID

    init(createdAt: Date, id: UUID) {
        self.createdAt = createdAt
        self.id = id
    }

    var microseconds: Int64 {
        Int64((createdAt.timeIntervalSince1970 * 1_000_000).rounded())
    }

    var encoded: String {
        Data("\(microseconds).\(id.uuidString.lowercased())".utf8).base64URLEncodedString()
    }

    init?(encoded text: String) {
        guard let data = Data(base64URLEncoded: text),
            let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = decoded.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let micros = Int64(parts[0]), micros >= 0,
            let id = UUID(uuidString: String(parts[1]))
        else { return nil }
        self.createdAt = Date(timeIntervalSince1970: Double(micros) / 1_000_000)
        self.id = id
    }
}

extension ContentCursor {
    /// `createdAt` as a `timestamptz` built from the exact microseconds. A bound `Date` would not
    /// do: PostgresNIO truncates it to microseconds, which can be one below the stored value.
    var timestampSQL: SQLQueryString {
        """
        (TIMESTAMPTZ 'epoch' + CAST(\(bind: microseconds) AS double precision) \
        * INTERVAL '1 microsecond')
        """
    }

    /// Rows strictly after the cursor in newest-first order (the post feed).
    func olderRows(table: String) -> SQLQueryString {
        "(\(ident: table).created_at, \(ident: table).id) < (\(timestampSQL), \(bind: id))"
    }

    /// Rows strictly after the cursor in oldest-first order (comments).
    func newerRows(table: String) -> SQLQueryString {
        "(\(ident: table).created_at, \(ident: table).id) > (\(timestampSQL), \(bind: id))"
    }
}

/// `?cursor=&limit=` of a page request.
struct PageRequest: Equatable, Sendable {
    var cursor: ContentCursor?
    var limit: Int

    init(cursor: ContentCursor? = nil, limit: Int = Page<PostResponse>.defaultLimit) {
        self.cursor = cursor
        self.limit = limit
    }

    /// Parses the query values. A missing limit is 20; values above 50 are clamped to 50; a
    /// non-number or a value below 1 is 400 `INVALID_REQUEST`, as is a cursor this server did not
    /// make.
    static func parse(cursor: String?, limit: String?) throws -> PageRequest {
        var request = PageRequest()
        if let limit, !limit.isEmpty {
            guard let value = Int(limit), value >= 1 else {
                throw APIError.invalidRequest("limit must be a positive integer")
            }
            request.limit = min(value, Page<PostResponse>.maximumLimit)
        }
        if let cursor, !cursor.isEmpty {
            guard let parsed = ContentCursor(encoded: cursor) else {
                throw APIError.invalidRequest("unknown cursor")
            }
            request.cursor = parsed
        }
        return request
    }

    /// How many rows to fetch: one more than the page, to learn whether another page follows.
    var fetchLimit: Int { limit + 1 }

    /// Splits rows fetched with `fetchLimit` into the page and its `nextCursor` (nil on the last
    /// page).
    func split<Row>(_ rows: [Row], cursor: (Row) throws -> ContentCursor) rethrows -> (
        rows: [Row], nextCursor: String?
    ) {
        guard rows.count > limit else { return (rows, nil) }
        let page = Array(rows.prefix(limit))
        return (page, try page.last.map { try cursor($0).encoded })
    }

    static func parse(_ req: Request) throws -> PageRequest {
        try parse(
            cursor: req.query[String.self, at: "cursor"], limit: req.query[String.self, at: "limit"])
    }
}
