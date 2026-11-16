import Foundation

/// A group invite code: 12 Crockford base32 characters (60 bits), design.md 6절.
///
/// Input is normalized: case, `-` and whitespace are ignored, `I`/`L` read as `1` and `O` as `0`.
/// The link is `https://pilgrim.delight-house.org/i/<code>`.
public struct InviteCode: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 12

    /// The normalized 12-character code, as stored in `invites.code`.
    public let rawValue: String

    /// Normalizes typed, pasted or scanned input. nil when it is not a valid code.
    public init?(normalizing input: String) {
        var characters: [Character] = []
        for character in input.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            let mapped: Character
            switch character {
            case "I", "L": mapped = "1"
            case "O": mapped = "0"
            default: mapped = character
            }
            guard Self.alphabetSet.contains(mapped) else { return nil }
            characters.append(mapped)
            if characters.count > Self.length { return nil }
        }
        guard characters.count == Self.length else { return nil }
        self.rawValue = String(characters)
    }

    /// A new random code.
    public static func generate(using rng: inout some RandomNumberGenerator) -> InviteCode {
        let characters = (0..<length).map { _ in alphabet[Int.random(in: 0..<32, using: &rng)] }
        return InviteCode(normalizing: String(characters))!
    }

    public static func generate() -> InviteCode {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    public var description: String { rawValue }

    /// `XXXX-XXXX-XXXX` for reading aloud or typing; normalizing it gives the same code back.
    public var grouped: String {
        let characters = Array(rawValue)
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// The invite link under `base` (the server's `PUBLIC_BASE_URL`).
    public func url(base: URL = APIPaths.productionBaseURL) -> URL {
        base.appendingPathComponent("i").appendingPathComponent(rawValue)
    }

    /// The code in an invite link (`/i/<code>`), or nil for any other URL.
    public init?(url: URL) {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, components[0] == "i" else { return nil }
        self.init(normalizing: components[1])
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let code = InviteCode(normalizing: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not an invite code: \(text)")
        }
        self = code
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static let alphabetSet = Set(alphabet)
}
