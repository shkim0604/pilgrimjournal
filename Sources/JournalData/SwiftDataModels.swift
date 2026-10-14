#if PILGRIM_SWIFTDATA
import Foundation
import JournalDomain
import SwiftData

@Model
final class JournalEntryEntity {
    var stableID: UUID = UUID()
    var kindRaw: String = JournalKind.diary.rawValue
    var title: String = ""
    var body: String = ""
    var occurredAt: Date = Date()
    var originalTimeZone: String?
    var tagsData: Data?
    var isStarred: Bool = false
    var isPinned: Bool = false
    var detailsData: Data?
    var sourceUUID: String?
    var sourceMetadata: Data?
    var currentRevisionID: UUID = UUID()
    var updatedAt: Date = Date()
    var modifiedByDeviceID: String = ""
    var deletedAt: Date?

    init() {}
}

@Model
final class EntryRevisionEntity {
    var stableID: UUID = UUID()
    var entryID: UUID = UUID()
    var parentRevisionID: UUID?
    var snapshotData: Data?
    var createdAt: Date = Date()
    var deviceID: String = ""
    var isRestore: Bool = false

    init() {}
}

@Model
final class AttachmentEntity {
    var stableID: UUID = UUID()
    var entryID: UUID = UUID()
    var originalName: String = ""
    var mimeType: String = "application/octet-stream"
    var checksum: String = ""
    var byteCount: Int64 = 0
    var stateRaw: String = AttachmentTransferState.local.rawValue
    var updatedAt: Date = Date()
    var deletedAt: Date?
    @Attribute(.externalStorage) public var binary: Data?

    init() {}
}

@Model
final class ClassificationRuleEntity {
    var stableID: UUID = UUID()
    var sourceRaw: String = ClassificationSource.tag.rawValue
    var value: String = ""
    var targetKindRaw: String = JournalKind.diary.rawValue
    var priority: Int = 0
    var updatedAt: Date = Date()

    init() {}
}

@Model
final class RestoreEpochEntity {
    var stableID: UUID = UUID()
    var createdAt: Date = Date()
    var modeRaw: String = RestoreMode.merge.rawValue
    var completedAt: Date?

    init() {}
}

@Model
final class ImportJobEntity {
    var stableID: UUID = UUID()
    var archiveFingerprint: String = ""
    var archiveDisplayName: String = ""
    var startedAt: Date = Date()
    var finishedAt: Date?
    var statusRaw: String = ImportJobStatus.analyzing.rawValue
    var totalCount: Int = 0
    var successCount: Int = 0
    var skippedCount: Int = 0
    var failureCount: Int = 0

    init() {}
}

@Model
final class ImportItemEntity {
    var stableID: UUID = UUID()
    var jobID: UUID = UUID()
    var sourceUUID: String = ""
    var entryID: UUID?
    var statusRaw: String = ImportItemStatus.pending.rawValue
    var message: String?

    init() {}
}

@Model
final class SourceSnapshotEntity {
    var stableID: UUID = UUID()
    var jobID: UUID = UUID()
    var sourceUUID: String = ""
    @Attribute(.externalStorage) public var rawJSON: Data?

    init() {}
}

#endif
