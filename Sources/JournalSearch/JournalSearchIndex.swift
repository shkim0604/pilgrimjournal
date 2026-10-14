import Foundation
import JournalDomain
import SQLite3

public struct JournalSearchQuery: Sendable {
    public var text: String
    public var kind: JournalKind?
    public var tags: [String]
    public var startDate: Date?
    public var endDate: Date?
    public var limit: Int

    public init(
        text: String = "",
        kind: JournalKind? = nil,
        tags: [String] = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 200
    ) {
        self.text = text
        self.kind = kind
        self.tags = tags
        self.startDate = startDate
        self.endDate = endDate
        self.limit = limit
    }
}

public struct JournalSearchHit: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var excerpt: String
    public var kind: JournalKind
    public var occurredAt: Date
}

public enum JournalSearchError: LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case let .sqlite(message): "검색 데이터베이스 오류: \(message)"
        }
    }
}

public final class JournalSearchIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let path: String

    public init(url: URL) throws {
        path = url.path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            sqlite3_open_v2(
                path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK
        else {
            throw JournalSearchError.sqlite("데이터베이스를 열 수 없습니다.")
        }
        try execute("PRAGMA journal_mode=WAL")
        try createSchema()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func upsert(_ entry: JournalEntryRecord) throws {
        try withLock {
            try execute(
                "DELETE FROM journal_fts WHERE id = ?",
                bindings: [.text(entry.id.uuidString)]
            )
            try execute(
                "DELETE FROM journal_search_meta WHERE id = ?",
                bindings: [.text(entry.id.uuidString)]
            )
            guard !entry.isDeleted else { return }
            let details = [
                entry.details.scriptureReference,
                entry.details.bookTitle,
                entry.details.bookAuthor,
                entry.details.mood,
            ].compactMap { $0 }.joined(separator: "\n")
            let tagPayload = "\n" + entry.tags.joined(separator: "\n") + "\n"
            try execute(
                """
                INSERT INTO journal_fts
                    (id, kind, occurred_at, title, body, tags, details)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(entry.id.uuidString),
                    .text(entry.kind.rawValue),
                    .double(entry.occurredAt.timeIntervalSince1970),
                    .text(entry.title),
                    .text(entry.body),
                    .text(tagPayload),
                    .text(details),
                ]
            )
            try insertSearchMetadata(for: entry)
        }
    }

    public func remove(id: UUID) throws {
        try withLock {
            try execute(
                "DELETE FROM journal_fts WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
            try execute(
                "DELETE FROM journal_search_meta WHERE id = ?",
                bindings: [.text(id.uuidString)]
            )
        }
    }

    public func rebuild(from entries: [JournalEntryRecord]) throws {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM journal_fts")
                try execute("DELETE FROM journal_search_meta")
                for entry in entries where !entry.isDeleted {
                    let details = [
                        entry.details.scriptureReference,
                        entry.details.bookTitle,
                        entry.details.bookAuthor,
                        entry.details.mood,
                    ].compactMap { $0 }.joined(separator: "\n")
                    let tagPayload = "\n" + entry.tags.joined(separator: "\n") + "\n"
                    try execute(
                        """
                        INSERT INTO journal_fts
                            (id, kind, occurred_at, title, body, tags, details)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(entry.id.uuidString),
                            .text(entry.kind.rawValue),
                            .double(entry.occurredAt.timeIntervalSince1970),
                            .text(entry.title),
                            .text(entry.body),
                            .text(tagPayload),
                            .text(details),
                        ]
                    )
                    try insertSearchMetadata(for: entry)
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func search(_ query: JournalSearchQuery) throws -> [JournalSearchHit] {
        try withLock {
            var conditions: [String] = []
            var bindings: [Binding] = []
            let normalized = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                if normalized.count >= 3 {
                    conditions.append("journal_fts MATCH ?")
                    let escaped = normalized.replacingOccurrences(of: "\"", with: "\"\"")
                    bindings.append(.text("\"\(escaped)\""))
                } else {
                    conditions.append(
                        "(title LIKE ? OR body LIKE ? OR tags LIKE ? OR details LIKE ?)"
                    )
                    let pattern = "%\(normalized)%"
                    bindings.append(contentsOf: Array(repeating: .text(pattern), count: 4))
                }
            }
            if let kind = query.kind {
                conditions.append("kind = ?")
                bindings.append(.text(kind.rawValue))
            }
            for tag in query.tags {
                conditions.append("tags LIKE ?")
                bindings.append(.text("%\n\(tag)\n%"))
            }
            if let start = query.startDate {
                conditions.append(
                    "COALESCE((SELECT local_day FROM journal_search_meta "
                        + "WHERE journal_search_meta.id = journal_fts.id), "
                        + "date(CAST(occurred_at AS REAL), 'unixepoch')) >= ?"
                )
                bindings.append(.text(Self.queryDay(start)))
            }
            if let end = query.endDate {
                conditions.append(
                    "COALESCE((SELECT local_day FROM journal_search_meta "
                        + "WHERE journal_search_meta.id = journal_fts.id), "
                        + "date(CAST(occurred_at AS REAL), 'unixepoch')) <= ?"
                )
                bindings.append(.text(Self.queryDay(end)))
            }
            let whereClause =
                conditions.isEmpty
                ? ""
                : "WHERE " + conditions.joined(separator: " AND ")
            bindings.append(.integer(Int64(max(1, query.limit))))
            return try select(
                """
                SELECT id, title, body, kind, occurred_at
                FROM journal_fts
                \(whereClause)
                ORDER BY CAST(occurred_at AS REAL) DESC, id ASC
                LIMIT ?
                """,
                bindings: bindings
            )
        }
    }

    public func integrityCheck() throws {
        try withLock {
            try execute("INSERT INTO journal_fts(journal_fts) VALUES('integrity-check')")
        }
    }

    public func indexedEntryIDs() throws -> Set<UUID> {
        try withLock {
            guard let database else { throw JournalSearchError.sqlite("연결이 닫혔습니다.") }
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    database,
                    "SELECT id FROM journal_search_meta",
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK
            else {
                throw sqliteError()
            }
            defer { sqlite3_finalize(statement) }
            var identifiers = Set<UUID>()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw sqliteError() }
                if let value = sqlite3_column_text(statement, 0),
                    let identifier = UUID(uuidString: String(cString: value))
                {
                    identifiers.insert(identifier)
                }
            }
            return identifiers
        }
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS journal_search_meta (
                id TEXT PRIMARY KEY NOT NULL,
                local_day TEXT NOT NULL
            )
            """
        )
        do {
            try execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS journal_fts
                USING fts5(
                    id UNINDEXED,
                    kind UNINDEXED,
                    occurred_at UNINDEXED,
                    title,
                    body,
                    tags,
                    details,
                    tokenize='trigram'
                )
                """
            )
        } catch {
            try execute("DROP TABLE IF EXISTS journal_fts")
            try execute(
                """
                CREATE VIRTUAL TABLE journal_fts
                USING fts5(
                    id UNINDEXED,
                    kind UNINDEXED,
                    occurred_at UNINDEXED,
                    title,
                    body,
                    tags,
                    details,
                    tokenize='unicode61'
                )
                """
            )
        }
    }

    private func insertSearchMetadata(for entry: JournalEntryRecord) throws {
        try execute(
            "INSERT OR REPLACE INTO journal_search_meta (id, local_day) VALUES (?, ?)",
            bindings: [
                .text(entry.id.uuidString),
                .text(Self.originalLocalDay(for: entry)),
            ]
        )
    }

    private static func originalLocalDay(for entry: JournalEntryRecord) -> String {
        var calendar = Calendar(identifier: .gregorian)
        if let identifier = entry.originalTimeZone,
            let timeZone = TimeZone(identifier: identifier)
        {
            calendar.timeZone = timeZone
        } else {
            calendar.timeZone = .current
        }
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: entry.occurredAt
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func queryDay(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func select(
        _ sql: String,
        bindings: [Binding]
    ) throws -> [JournalSearchHit] {
        guard let database else { throw JournalSearchError.sqlite("연결이 닫혔습니다.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var values: [JournalSearchHit] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw sqliteError() }
            guard let idText = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idText)),
                let kindText = sqlite3_column_text(statement, 3),
                let kind = JournalKind(rawValue: String(cString: kindText))
            else {
                continue
            }
            let title = sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? ""
            let body = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? ""
            let excerpt = body.count > 160 ? String(body.prefix(160)) + "…" : body
            values.append(
                JournalSearchHit(
                    id: id,
                    title: title,
                    excerpt: excerpt,
                    kind: kind,
                    occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                ))
        }
        return values
    }

    private func execute(
        _ sql: String,
        bindings: [Binding] = []
    ) throws {
        guard let database else { throw JournalSearchError.sqlite("연결이 닫혔습니다.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            if status == SQLITE_ROW { continue }
            throw sqliteError()
        }
    }

    private func bind(_ values: [Binding], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case let .text(text):
                status = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case let .double(double):
                status = sqlite3_bind_double(statement, index, double)
            case let .integer(integer):
                status = sqlite3_bind_int64(statement, index, integer)
            }
            guard status == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func sqliteError() -> JournalSearchError {
        let message =
            database.flatMap(sqlite3_errmsg).map(String.init(cString:))
            ?? "알 수 없는 SQLite 오류"
        return .sqlite(message)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

private enum Binding {
    case text(String)
    case double(Double)
    case integer(Int64)
}

private let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
