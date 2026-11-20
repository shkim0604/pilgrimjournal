import Foundation

/// Which of my prayer-note topics a posted group prayer line came from, so marking one
/// answered marks the other. Device-side only: never sent to the group server.
public struct GroupPrayerLink: Codable, Equatable, Sendable {
    public var postID: UUID
    public var groupID: UUID
    /// The line's index in the post's `items`.
    public var itemIndex: Int
    public var entryID: UUID
    public var topicID: UUID
    /// The post's `expiresAt`; the link is dropped once it passes.
    public var expiresAt: Date

    public init(
        postID: UUID, groupID: UUID, itemIndex: Int, entryID: UUID, topicID: UUID,
        expiresAt: Date
    ) {
        self.postID = postID
        self.groupID = groupID
        self.itemIndex = itemIndex
        self.entryID = entryID
        self.topicID = topicID
        self.expiresAt = expiresAt
    }
}

/// Keeps the `GroupPrayerLink` list in the iCloud key-value store (UserDefaults for a
/// local-only scope, which has no cloud store), so every device of the user follows it.
@MainActor
public final class GroupPrayerLinkStore {
    public nonisolated static let key = "journal-group-prayer-links"

    private let defaults: UserDefaults
    private let cloudStore: (any KindCatalogCloudStore)?
    private let now: () -> Date

    public init(
        defaults: UserDefaults, cloudStore: (any KindCatalogCloudStore)?,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.now = now
    }

    /// The links whose post has not expired; expired ones are pruned from the store.
    public func links() -> [GroupPrayerLink] {
        let all = Self.decode(cloudStore?.data(forKey: Self.key) ?? defaults.data(forKey: Self.key))
        let current = now()
        let live = all.filter { $0.expiresAt > current }
        if live.count != all.count { write(live) }
        return live
    }

    /// Adds links, replacing any already kept for the same post line.
    public func add(_ new: [GroupPrayerLink]) {
        guard !new.isEmpty else { return }
        let kept = links().filter { link in
            !new.contains { $0.postID == link.postID && $0.itemIndex == link.itemIndex }
        }
        write(kept + new)
    }

    /// Moves the links of `postID` to the post's current `expiresAt` (a mark keeps the post
    /// longer).
    public func updateExpiry(postID: UUID, to expiresAt: Date) {
        let all = links()
        guard all.contains(where: { $0.postID == postID && $0.expiresAt != expiresAt }) else {
            return
        }
        write(
            all.map { link in
                var link = link
                if link.postID == postID { link.expiresAt = expiresAt }
                return link
            })
    }

    private func write(_ links: [GroupPrayerLink]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(links) else { return }
        if let cloudStore {
            cloudStore.set(data, forKey: Self.key)
            cloudStore.synchronize()
        } else {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func decode(_ data: Data?) -> [GroupPrayerLink] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GroupPrayerLink].self, from: data)) ?? []
    }
}
