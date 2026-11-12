import Foundation

/// One unit of family sharing: a notebook shared as a whole, or a single shared entry.
/// Each space is one CloudKit record zone with a zone-wide share, so its entries,
/// revisions and attachments are shared together and live apart from the private journal.
public struct SharedSpaceRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, Sendable {
        case notebook
        case entry
    }

    public enum Role: String, Codable, Sendable {
        case owner
        case participant
    }

    public var id: UUID
    public var scope: Scope
    /// The notebook name, or the entry title for a single shared entry.
    public var name: String
    public var role: Role
    /// The owner's name from the share, shown on spaces shared with this user.
    public var ownerName: String?
    public var participantCount: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        scope: Scope,
        name: String,
        role: Role,
        ownerName: String? = nil,
        participantCount: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.scope = scope
        self.name = name
        self.role = role
        self.ownerName = ownerName
        self.participantCount = participantCount
        self.updatedAt = updatedAt
    }

    public var zoneName: String { Self.zoneName(for: id) }

    /// Shared zones are named apart from Core Data's `com.apple.coredata.cloudkit` zones,
    /// so private-journal tooling (data wipe, account deletion) can tell them apart.
    public static let zoneNamePrefix = "pilgrim-share-"

    public static func zoneName(for id: UUID) -> String {
        zoneNamePrefix + id.uuidString.lowercased()
    }

    public static func id(fromZoneName zoneName: String) -> UUID? {
        guard zoneName.hasPrefix(zoneNamePrefix) else { return nil }
        return UUID(uuidString: String(zoneName.dropFirst(zoneNamePrefix.count)))
    }
}

/// The kind's look at the time an entry was shared. Family members may not have the same
/// custom kinds, so shared entries carry the name, colour and icon to label themselves.
public struct SharedKindSnapshot: Codable, Equatable, Sendable {
    public var kind: JournalKind
    public var name: String
    public var colorToken: KindColorToken
    public var iconToken: String

    public init(kind: JournalKind, name: String, colorToken: KindColorToken, iconToken: String) {
        self.kind = kind
        self.name = name
        self.colorToken = colorToken
        self.iconToken = iconToken
    }

    public init(_ definition: KindDefinition) {
        self.init(
            kind: definition.kind,
            name: definition.name,
            colorToken: definition.colorToken,
            iconToken: definition.iconToken
        )
    }
}
