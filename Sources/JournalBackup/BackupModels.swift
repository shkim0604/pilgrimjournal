import Foundation
import JournalDomain

public struct BackupManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var schemaVersion: Int
    public var createdAt: Date
    public var files: [String: String]
    public var includesSourceSnapshots: Bool
    public var includesKindCatalog: Bool

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        schemaVersion: Int = 1,
        createdAt: Date = .now,
        files: [String: String],
        includesSourceSnapshots: Bool,
        includesKindCatalog: Bool = false
    ) {
        self.formatVersion = formatVersion
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.files = files
        self.includesSourceSnapshots = includesSourceSnapshots
        self.includesKindCatalog = includesKindCatalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        files = try container.decode([String: String].self, forKey: .files)
        includesSourceSnapshots = try container.decode(
            Bool.self, forKey: .includesSourceSnapshots)
        includesKindCatalog =
            try container.decodeIfPresent(Bool.self, forKey: .includesKindCatalog) ?? false
    }
}

public struct BackupAttachment: Codable, Equatable, Sendable {
    public var record: AttachmentRecord
    public var binary: Data?

    public init(record: AttachmentRecord, binary: Data?) {
        self.record = record
        self.binary = binary
    }
}

public struct BackupSourceSnapshot: Codable, Equatable, Sendable {
    public var sourceUUID: String
    public var rawJSON: Data

    public init(sourceUUID: String, rawJSON: Data) {
        self.sourceUUID = sourceUUID
        self.rawJSON = rawJSON
    }
}

public struct BackupContents: Sendable {
    public var manifest: BackupManifest
    public var entries: [JournalEntryRecord]
    public var revisions: [EntryRevisionRecord]
    public var rules: [ClassificationRuleRecord]
    public var attachments: [BackupAttachment]
    public var sourceSnapshots: [BackupSourceSnapshot]
    public var kindCatalog: KindCatalog?

    public init(
        manifest: BackupManifest,
        entries: [JournalEntryRecord],
        revisions: [EntryRevisionRecord],
        rules: [ClassificationRuleRecord],
        attachments: [BackupAttachment],
        sourceSnapshots: [BackupSourceSnapshot],
        kindCatalog: KindCatalog? = nil
    ) {
        self.manifest = manifest
        self.entries = entries
        self.revisions = revisions
        self.rules = rules
        self.attachments = attachments
        self.sourceSnapshots = sourceSnapshots
        self.kindCatalog = kindCatalog
    }
}

public struct RestorePlan: Sendable {
    public var mode: RestoreMode
    public var upserts: [JournalEntryRecord]
    public var conflicts: [(current: JournalEntryRecord, backup: JournalEntryRecord)]
    public var tombstoneIDs: [UUID]

    public init(
        mode: RestoreMode,
        upserts: [JournalEntryRecord],
        conflicts: [(current: JournalEntryRecord, backup: JournalEntryRecord)],
        tombstoneIDs: [UUID]
    ) {
        self.mode = mode
        self.upserts = upserts
        self.conflicts = conflicts
        self.tombstoneIDs = tombstoneIDs
    }
}

public struct RestoreResult: Equatable, Sendable {
    public var restored: Int
    public var tombstoned: Int
    public var conflicts: Int
}
