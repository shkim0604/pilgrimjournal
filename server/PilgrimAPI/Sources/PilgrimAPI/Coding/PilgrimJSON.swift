import Foundation

/// The JSON coders every group-server request and response goes through (design.md 2절).
///
/// - Dates are ISO 8601 in UTC. Written with milliseconds (`2026-11-14T13:05:00.123Z`), read with
///   or without fractional seconds.
/// - Keys are sorted so encoded bodies are deterministic (fixtures, idempotency comparisons).
/// - UUIDs are written as lowercase strings (see `KeyedEncodingContainer+LowercaseUUID.swift`).
public enum PilgrimJSON {
    /// A fresh encoder. `JSONEncoder` is a class, so callers get their own instance.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PilgrimDateFormat.string(from: date))
        }
        return encoder
    }

    /// A fresh decoder.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PilgrimDateFormat.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO 8601 UTC date, got \(text)")
            }
            return date
        }
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// ISO 8601 UTC timestamps as the API writes and reads them.
public enum PilgrimDateFormat {
    private static let withFraction = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)
    private static let withoutFraction = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false, timeZone: TimeZone(identifier: "UTC")!)

    /// `2026-11-14T13:05:00.123Z`.
    public static func string(from date: Date) -> String {
        withFraction.format(date)
    }

    /// Accepts `2026-11-14T13:05:00.123Z` and `2026-11-14T13:05:00Z`.
    public static func date(from text: String) -> Date? {
        if let date = try? withFraction.parse(text) {
            return date
        }
        return try? withoutFraction.parse(text)
    }
}
