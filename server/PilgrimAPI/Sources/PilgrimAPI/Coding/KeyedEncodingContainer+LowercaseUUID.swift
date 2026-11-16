import Foundation

// design.md 2절: IDs are lowercase UUID strings. Foundation's `UUID` encodes uppercase, so these
// overloads win over the generic `encode(_:forKey:)` in every Codable conformance synthesized in
// this module. They are internal on purpose: they apply to PilgrimAPI DTOs only. Decoding needs
// nothing, because `UUID(uuidString:)` accepts either case.
extension KeyedEncodingContainer {
    mutating func encode(_ value: UUID, forKey key: Key) throws {
        try encode(value.pilgrimString, forKey: key)
    }

    mutating func encodeIfPresent(_ value: UUID?, forKey key: Key) throws {
        guard let value else { return }
        try encode(value.pilgrimString, forKey: key)
    }

    mutating func encode(_ value: [UUID], forKey key: Key) throws {
        try encode(value.map(\.pilgrimString), forKey: key)
    }

    mutating func encodeIfPresent(_ value: [UUID]?, forKey key: Key) throws {
        guard let value else { return }
        try encode(value.map(\.pilgrimString), forKey: key)
    }
}

extension UUID {
    /// The lowercase form the API uses in JSON bodies and URL paths.
    public var pilgrimString: String { uuidString.lowercased() }
}
