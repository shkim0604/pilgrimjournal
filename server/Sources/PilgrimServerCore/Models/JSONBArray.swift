import FluentPostgresDriver
import Foundation

/// An array stored in a single `jsonb` column (`posts.items`).
///
/// Fluent would otherwise bind a Swift array as a Postgres array (`jsonb[]`), which a `jsonb`
/// column refuses. This wrapper encodes as one JSON array instead, in both Fluent and raw SQL
/// binds.
public struct JSONBArray<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable,
    PostgresEncodable, PostgresDecodable
{
    public var elements: [Element]

    public init(_ elements: [Element]) {
        self.elements = elements
    }

    public init(from decoder: any Decoder) throws {
        elements = try decoder.singleValueContainer().decode([Element].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}
