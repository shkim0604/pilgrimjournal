import CloudKit
import Foundation
import JournalDomain

public enum SharedRecordType {
    public static let entry = "SharedEntry"
    public static let revision = "SharedRevision"
}

public enum SharedRecordError: Error, Equatable {
    case missingField(String)
    case invalidRecordName(String)
}

/// A shared entry as it travels through CloudKit: the entry plus its kind's look, so a
/// family member without that kind can still label it.
public struct SharedEntryPayload: Equatable, Sendable {
    public var entry: JournalEntryRecord
    public var kind: SharedKindSnapshot

    public init(entry: JournalEntryRecord, kind: SharedKindSnapshot) {
        self.entry = entry
        self.kind = kind
    }
}

/// Maps shared entries and revisions to CloudKit records and back.
///
/// Note content (title, body, tags, kind-specific details, kind name, revision snapshots)
/// goes in `encryptedValues`, so it is end-to-end encrypted between family members'
/// devices. Day One source fields stay out of shared records: they are import bookkeeping
/// for the owner's private journal, not something to hand to other people.
public enum SharedRecordMapper {
    public static func zoneID(
        for space: SharedSpaceRecord,
        ownerName: String = CKCurrentUserDefaultName
    ) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: space.zoneName, ownerName: ownerName)
    }

    public static func recordID(for id: UUID, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    // MARK: Entries

    public static func write(_ payload: SharedEntryPayload, to record: CKRecord) {
        let entry = payload.entry
        record[Field.kind] = entry.kind.id
        record[Field.occurredAt] = entry.occurredAt
        record[Field.originalTimeZone] = entry.originalTimeZone
        record[Field.isStarred] = entry.isStarred
        record[Field.isPinned] = entry.isPinned
        record[Field.currentRevisionID] = entry.currentRevisionID.uuidString
        record[Field.updatedAt] = entry.updatedAt
        record[Field.modifiedByDeviceID] = entry.modifiedByDeviceID
        record[Field.deletedAt] = entry.deletedAt
        record[Field.kindColor] = payload.kind.colorToken.rawValue
        record[Field.kindIcon] = payload.kind.iconToken

        let encrypted = record.encryptedValues
        encrypted[Field.title] = entry.title
        encrypted[Field.body] = entry.body
        encrypted[Field.tags] = entry.tags
        encrypted[Field.details] = try? JSONEncoder().encode(entry.details)
        encrypted[Field.kindName] = payload.kind.name
    }

    public static func entryPayload(from record: CKRecord) throws -> SharedEntryPayload {
        let encrypted = record.encryptedValues
        let kind = JournalKind(id: try value(record[Field.kind], Field.kind))
        let details = try JSONDecoder().decode(
            EntryDetails.self, from: try value(encrypted[Field.details], Field.details))
        let entry = JournalEntryRecord(
            id: try uuid(record.recordID.recordName),
            kind: kind,
            title: try value(encrypted[Field.title], Field.title),
            body: try value(encrypted[Field.body], Field.body),
            occurredAt: try value(record[Field.occurredAt], Field.occurredAt),
            originalTimeZone: record[Field.originalTimeZone] as? String,
            tags: encrypted[Field.tags] as? [String] ?? [],
            isStarred: (record[Field.isStarred] as? Bool) ?? false,
            isPinned: (record[Field.isPinned] as? Bool) ?? false,
            details: details,
            sourceUUID: nil,
            sourceMetadata: nil,
            currentRevisionID: try uuid(
                try value(record[Field.currentRevisionID], Field.currentRevisionID)),
            updatedAt: try value(record[Field.updatedAt], Field.updatedAt),
            modifiedByDeviceID: try value(
                record[Field.modifiedByDeviceID], Field.modifiedByDeviceID),
            deletedAt: record[Field.deletedAt] as? Date
        )
        let snapshot = SharedKindSnapshot(
            kind: kind,
            name: encrypted[Field.kindName] as? String ?? kind.fallbackName,
            colorToken: (record[Field.kindColor] as? String).flatMap(KindColorToken.init) ?? .stone,
            iconToken: record[Field.kindIcon] as? String ?? "tag"
        )
        return SharedEntryPayload(entry: entry, kind: snapshot)
    }

    // MARK: Revisions

    public static func write(_ revision: EntryRevisionRecord, to record: CKRecord) throws {
        var snapshot = revision.snapshot
        snapshot.sourceUUID = nil
        snapshot.sourceMetadata = nil
        record[Field.entryID] = revision.entryID.uuidString
        record[Field.parentRevisionID] = revision.parentRevisionID?.uuidString
        record[Field.createdAt] = revision.createdAt
        record[Field.deviceID] = revision.deviceID
        record[Field.isRestore] = revision.isRestore
        record.encryptedValues[Field.snapshot] = try JSONEncoder().encode(snapshot)
    }

    public static func revision(from record: CKRecord) throws -> EntryRevisionRecord {
        EntryRevisionRecord(
            id: try uuid(record.recordID.recordName),
            entryID: try uuid(try value(record[Field.entryID], Field.entryID)),
            parentRevisionID: (record[Field.parentRevisionID] as? String).flatMap(
                UUID.init(uuidString:)),
            snapshot: try JSONDecoder().decode(
                JournalEntryDraft.self,
                from: try value(record.encryptedValues[Field.snapshot], Field.snapshot)
            ),
            createdAt: try value(record[Field.createdAt], Field.createdAt),
            deviceID: try value(record[Field.deviceID], Field.deviceID),
            isRestore: (record[Field.isRestore] as? Bool) ?? false
        )
    }

    // MARK: Helpers

    enum Field {
        static let kind = "kind"
        static let kindName = "kindName"
        static let kindColor = "kindColor"
        static let kindIcon = "kindIcon"
        static let title = "title"
        static let body = "body"
        static let occurredAt = "occurredAt"
        static let originalTimeZone = "originalTimeZone"
        static let tags = "tags"
        static let isStarred = "isStarred"
        static let isPinned = "isPinned"
        static let details = "details"
        static let currentRevisionID = "currentRevisionID"
        static let updatedAt = "updatedAt"
        static let modifiedByDeviceID = "modifiedByDeviceID"
        static let deletedAt = "deletedAt"
        static let entryID = "entryID"
        static let parentRevisionID = "parentRevisionID"
        static let snapshot = "snapshot"
        static let createdAt = "createdAt"
        static let deviceID = "deviceID"
        static let isRestore = "isRestore"
    }

    private static func value<Value>(_ raw: Any?, _ field: String) throws -> Value {
        guard let value = raw as? Value else { throw SharedRecordError.missingField(field) }
        return value
    }

    private static func uuid(_ string: String) throws -> UUID {
        guard let id = UUID(uuidString: string) else {
            throw SharedRecordError.invalidRecordName(string)
        }
        return id
    }
}
