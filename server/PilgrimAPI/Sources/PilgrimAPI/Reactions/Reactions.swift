import Foundation

/// A reaction on a post: one system emoji, or a sticker of the post's group.
///
/// JSON: `{"type":"emoji","emoji":"🙏"}` or `{"type":"sticker","stickerId":"<uuid>"}`.
public enum ReactionKey: Hashable, Sendable, Codable {
    case emoji(String)
    case sticker(UUID)

    private enum CodingKeys: String, CodingKey {
        case type, emoji, stickerId
    }

    private enum KeyType: String, Codable {
        case emoji, sticker
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KeyType.self, forKey: .type) {
        case .emoji:
            self = .emoji(try container.decode(String.self, forKey: .emoji))
        case .sticker:
            self = .sticker(try container.decode(UUID.self, forKey: .stickerId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let emoji):
            try container.encode(KeyType.emoji, forKey: .type)
            try container.encode(emoji, forKey: .emoji)
        case .sticker(let id):
            try container.encode(KeyType.sticker, forKey: .type)
            try container.encode(id, forKey: .stickerId)
        }
    }

    /// The `DELETE /posts/:id/reactions` query item (`emoji=` or `stickerId=`).
    public var queryItem: URLQueryItem {
        switch self {
        case .emoji(let emoji): URLQueryItem(name: "emoji", value: emoji)
        case .sticker(let id): URLQueryItem(name: "stickerId", value: id.pilgrimString)
        }
    }
}

/// One reaction kind on a post with its count (blocked users excluded).
public struct ReactionSummary: Equatable, Hashable, Sendable, Codable {
    public var key: ReactionKey
    public var count: Int
    public var reactedByMe: Bool

    public init(key: ReactionKey, count: Int, reactedByMe: Bool) {
        self.key = key
        self.count = count
        self.reactedByMe = reactedByMe
    }
}

/// `PUT /posts/:id/reactions` → `[ReactionSummary]`. Naturally idempotent.
public struct ReactionRequest: Equatable, Sendable, Codable {
    public var key: ReactionKey

    public init(key: ReactionKey) {
        self.key = key
    }
}
