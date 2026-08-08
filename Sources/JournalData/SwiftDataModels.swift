#if PILGRIM_SWIFTDATA
import Foundation
import JournalDomain
import SwiftData

@Model
public final class JournalEntryEntity {
    public var stableID: UUID = UUID()
    public var kindRaw: String = JournalKind.diary.rawValue
    public var title: String = ""
    public var body: String = ""
    public var occurredAt: Date = Date()
    public var originalTimeZone: String?
    public var tagsData: Data?
    public var isStarred: Bool = false
    public var isPinned: Bool = false
    public var detailsData: Data?
    public var sourceUUID: String?
    public var sourceMetadata: Data?
    public var currentRevisionID: UUID = UUID()
    public var updatedAt: Date = Date()
    public var modifiedByDeviceID: String = ""
    public var deletedAt: Date?

    public init() {}
}

@Model
public final class EntryRevisionEntity {
    public var stableID: UUID = UUID()
    public var entryID: UUID = UUID()
    public var parentRevisionID: UUID?
    public var snapshotData: Data?
    public var createdAt: Date = Date()
    public var deviceID: String = ""
    public var isRestore: Bool = false

    public init() {}
}

@Model
public final class AttachmentEntity {
    public var stableID: UUID = UUID()
    public var entryID: UUID = UUID()
    public var originalName: String = ""
    public var mimeType: String = "application/octet-stream"
    public var checksum: String = ""
    public var byteCount: Int64 = 0
    public var stateRaw: String = AttachmentTransferState.local.rawValue
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    @Attribute(.externalStorage) public var binary: Data?

    public init() {}
}

@Model
public final class ClassificationRuleEntity {
    public var stableID: UUID = UUID()
    public var sourceRaw: String = ClassificationSource.tag.rawValue
    public var value: String = ""
    public var targetKindRaw: String = JournalKind.diary.rawValue
    public var priority: Int = 0
    public var updatedAt: Date = Date()

    public init() {}
}

@Model
public final class RestoreEpochEntity {
    public var stableID: UUID = UUID()
    public var createdAt: Date = Date()
    public var modeRaw: String = RestoreMode.merge.rawValue
    public var completedAt: Date?

    public init() {}
}

@Model
public final class ImportJobEntity {
    public var stableID: UUID = UUID()
    public var archiveFingerprint: String = ""
    public var archiveDisplayName: String = ""
    public var startedAt: Date = Date()
    public var finishedAt: Date?
    public var statusRaw: String = ImportJobStatus.analyzing.rawValue
    public var totalCount: Int = 0
    public var successCount: Int = 0
    public var skippedCount: Int = 0
    public var failureCount: Int = 0

    public init() {}
}

@Model
public final class ImportItemEntity {
    public var stableID: UUID = UUID()
    public var jobID: UUID = UUID()
    public var sourceUUID: String = ""
    public var entryID: UUID?
    public var statusRaw: String = ImportItemStatus.pending.rawValue
    public var message: String?

    public init() {}
}

@Model
public final class SourceSnapshotEntity {
    public var stableID: UUID = UUID()
    public var jobID: UUID = UUID()
    public var sourceUUID: String = ""
    @Attribute(.externalStorage) public var rawJSON: Data?

    public init() {}
}

#endif
