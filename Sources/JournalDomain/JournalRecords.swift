import Foundation

public struct JournalEntryDraft: Codable, Equatable, Sendable {
    public var id: UUID?
    public var kind: JournalKind
    public var title: String
    public var body: String
    public var occurredAt: Date
    public var originalTimeZone: String?
    public var tags: [String]
    public var isStarred: Bool
    public var isPinned: Bool
    public var details: EntryDetails
    public var sourceUUID: String?
    public var sourceMetadata: Data?

    public init(
        id: UUID? = nil,
        kind: JournalKind,
        title: String = "",
        body: String = "",
        occurredAt: Date = .now,
        originalTimeZone: String? = nil,
        tags: [String] = [],
        isStarred: Bool = false,
        isPinned: Bool = false,
        details: EntryDetails = EntryDetails(),
        sourceUUID: String? = nil,
        sourceMetadata: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
        self.originalTimeZone = originalTimeZone
        self.tags = tags
        self.isStarred = isStarred
        self.isPinned = isPinned
        self.details = details
        self.sourceUUID = sourceUUID
        self.sourceMetadata = sourceMetadata
    }

    public func validated(manual: Bool) throws -> JournalEntryDraft {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tags = Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        if manual && !kind.canCreateManually { throw JournalError.invalidManualKind }
        if copy.title.isEmpty && copy.body.isEmpty { throw JournalError.emptyContent }
        copy.details = try details.validated(for: kind)
        return copy
    }
}

public struct JournalEntryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: JournalKind
    public var title: String
    public var body: String
    public var occurredAt: Date
    public var originalTimeZone: String?
    public var tags: [String]
    public var isStarred: Bool
    public var isPinned: Bool
    public var details: EntryDetails
    public var sourceUUID: String?
    public var sourceMetadata: Data?
    public var currentRevisionID: UUID
    public var updatedAt: Date
    public var modifiedByDeviceID: String
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: UUID,
        kind: JournalKind,
        title: String,
        body: String,
        occurredAt: Date,
        originalTimeZone: String?,
        tags: [String],
        isStarred: Bool,
        isPinned: Bool,
        details: EntryDetails,
        sourceUUID: String?,
        sourceMetadata: Data?,
        currentRevisionID: UUID,
        updatedAt: Date,
        modifiedByDeviceID: String,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
        self.originalTimeZone = originalTimeZone
        self.tags = tags
        self.isStarred = isStarred
        self.isPinned = isPinned
        self.details = details
        self.sourceUUID = sourceUUID
        self.sourceMetadata = sourceMetadata
        self.currentRevisionID = currentRevisionID
        self.updatedAt = updatedAt
        self.modifiedByDeviceID = modifiedByDeviceID
        self.deletedAt = deletedAt
    }

    public var draft: JournalEntryDraft {
        JournalEntryDraft(
            id: id,
            kind: kind,
            title: title,
            body: body,
            occurredAt: occurredAt,
            originalTimeZone: originalTimeZone,
            tags: tags,
            isStarred: isStarred,
            isPinned: isPinned,
            details: details,
            sourceUUID: sourceUUID,
            sourceMetadata: sourceMetadata
        )
    }
}

public struct EntryRevisionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entryID: UUID
    public var parentRevisionID: UUID?
    public var snapshot: JournalEntryDraft
    public var createdAt: Date
    public var deviceID: String
    public var isRestore: Bool

    public init(
        id: UUID = UUID(),
        entryID: UUID,
        parentRevisionID: UUID?,
        snapshot: JournalEntryDraft,
        createdAt: Date = .now,
        deviceID: String,
        isRestore: Bool = false
    ) {
        self.id = id
        self.entryID = entryID
        self.parentRevisionID = parentRevisionID
        self.snapshot = snapshot
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.isRestore = isRestore
    }
}

public enum AttachmentTransferState: String, Codable, Sendable {
    case local
    case pending
    case uploaded
    case downloading
    case failed
}

public struct AttachmentRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var entryID: UUID
    public var originalName: String
    public var mimeType: String
    public var checksum: String
    public var byteCount: Int64
    public var state: AttachmentTransferState
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        entryID: UUID,
        originalName: String,
        mimeType: String,
        checksum: String,
        byteCount: Int64,
        state: AttachmentTransferState = .local,
        updatedAt: Date = .now,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.entryID = entryID
        self.originalName = originalName
        self.mimeType = mimeType
        self.checksum = checksum
        self.byteCount = byteCount
        self.state = state
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum ClassificationSource: String, Codable, Sendable {
    case tag
    case templateUUID
    case templateTitle
}

public struct ClassificationRuleRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: ClassificationSource
    public var value: String
    public var targetKind: JournalKind
    public var priority: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        source: ClassificationSource,
        value: String,
        targetKind: JournalKind,
        priority: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.source = source
        self.value = value
        self.targetKind = targetKind
        self.priority = priority
        self.updatedAt = updatedAt
    }
}

public struct RestoreEpochRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var mode: RestoreMode

    public init(id: UUID = UUID(), createdAt: Date = .now, mode: RestoreMode) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
    }
}

public enum RestoreMode: String, Codable, Sendable {
    case merge
    case replace
}
