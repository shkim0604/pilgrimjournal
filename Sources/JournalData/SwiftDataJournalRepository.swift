#if PILGRIM_SWIFTDATA
import Foundation
import JournalDomain
import SwiftData

@MainActor
public final class SwiftDataJournalRepository:
    JournalRepository,
    AttachmentRepository,
    BackupRestoreRepository
{
    public let container: ModelContainer
    private let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func list(
        kind: JournalKind?,
        includeDeleted: Bool = false,
        limit: Int = 200
    ) throws -> [JournalEntryRecord] {
        var descriptor = FetchDescriptor<JournalEntryEntity>(
            sortBy: [
                SortDescriptor(\JournalEntryEntity.occurredAt, order: .reverse),
                SortDescriptor(\JournalEntryEntity.stableID),
            ]
        )
        descriptor.fetchLimit = limit
        let entities = try context.fetch(descriptor)
        return try entities.compactMap { entity in
            guard includeDeleted || entity.deletedAt == nil else { return nil }
            if let kind, entity.kindRaw != kind.rawValue { return nil }
            return try map(entity)
        }
    }

    public func page(
        kind: JournalKind?,
        includeDeleted: Bool = false,
        after cursor: JournalTimelineCursor?,
        limit: Int
    ) throws -> JournalTimelinePage {
        let descriptor = FetchDescriptor<JournalEntryEntity>(
            sortBy: [
                SortDescriptor(\JournalEntryEntity.occurredAt, order: .reverse),
                SortDescriptor(\JournalEntryEntity.stableID),
            ]
        )
        let pageSize = max(1, limit)
        let candidates: [JournalEntryRecord] = try context.fetch(descriptor).compactMap {
            entity -> JournalEntryRecord? in
            guard includeDeleted || entity.deletedAt == nil else { return nil }
            if let kind, entity.kindRaw != kind.rawValue { return nil }
            if let cursor {
                if entity.occurredAt > cursor.occurredAt { return nil }
                if entity.occurredAt == cursor.occurredAt,
                   entity.stableID.uuidString <= cursor.entryID.uuidString {
                    return nil
                }
            }
            return try map(entity)
        }
        let values = Array(candidates.prefix(pageSize))
        let hasMore = candidates.count > values.count
        let nextCursor = hasMore ? values.last.map {
            JournalTimelineCursor(occurredAt: $0.occurredAt, entryID: $0.id)
        } : nil
        return JournalTimelinePage(entries: values, nextCursor: nextCursor)
    }

    public func entry(id: UUID) throws -> JournalEntryRecord? {
        try findEntry(id: id).map(map)
    }

    public func entry(sourceUUID: String) throws -> JournalEntryRecord? {
        let normalized = sourceUUID.lowercased()
        var descriptor = FetchDescriptor<JournalEntryEntity>(
            predicate: #Predicate { entity in
                entity.sourceUUID != nil
            }
        )
        descriptor.fetchLimit = 500
        return try context.fetch(descriptor)
            .first(where: { $0.sourceUUID?.lowercased() == normalized })
            .map(map)
    }

    public func save(
        _ draft: JournalEntryDraft,
        deviceID: String,
        at date: Date = .now
    ) throws -> JournalEntryRecord {
        let validated = try draft.validated(manual: draft.sourceUUID == nil)
        if let sourceUUID = validated.sourceUUID,
           let duplicate = try entry(sourceUUID: sourceUUID),
           duplicate.id != validated.id {
            throw JournalError.duplicateSource(sourceUUID)
        }

        let entryID = validated.id
            ?? validated.sourceUUID.map(StableIdentifier.fromDayOne)
            ?? UUID()
        let entity = try findEntry(id: entryID) ?? JournalEntryEntity()
        let parentRevisionID = entity.stableID == entryID ? entity.currentRevisionID : nil
        let revisionID = UUID()

        entity.stableID = entryID
        entity.kindRaw = validated.kind.rawValue
        entity.title = validated.title
        entity.body = validated.body
        entity.occurredAt = validated.occurredAt
        entity.originalTimeZone = validated.originalTimeZone
        entity.tagsData = try encoder.encode(validated.tags)
        entity.isStarred = validated.isStarred
        entity.isPinned = validated.isPinned
        entity.detailsData = try encoder.encode(validated.details)
        entity.sourceUUID = validated.sourceUUID
        entity.sourceMetadata = validated.sourceMetadata
        entity.currentRevisionID = revisionID
        entity.updatedAt = date
        entity.modifiedByDeviceID = deviceID
        entity.deletedAt = nil
        if entity.modelContext == nil { context.insert(entity) }

        let revision = EntryRevisionEntity()
        revision.stableID = revisionID
        revision.entryID = entryID
        revision.parentRevisionID = parentRevisionID
        revision.snapshotData = try encoder.encode(validated)
        revision.createdAt = date
        revision.deviceID = deviceID
        context.insert(revision)
        try context.save()
        return try map(entity)
    }

    public func revisions(entryID: UUID) throws -> [EntryRevisionRecord] {
        var descriptor = FetchDescriptor<EntryRevisionEntity>(
            predicate: #Predicate { revision in
                revision.entryID == entryID
            },
            sortBy: [SortDescriptor(\EntryRevisionEntity.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1_000
        return try context.fetch(descriptor).map(map)
    }

    public func restore(
        entryID: UUID,
        revisionID: UUID,
        deviceID: String,
        at date: Date = .now
    ) throws -> JournalEntryRecord {
        guard let revision = try findRevision(id: revisionID),
              revision.entryID == entryID,
              let snapshotData = revision.snapshotData else {
            throw JournalError.revisionNotFound
        }
        var draft = try decoder.decode(JournalEntryDraft.self, from: snapshotData)
        draft.id = entryID
        let record = try save(draft, deviceID: deviceID, at: date)
        guard let created = try findRevision(id: record.currentRevisionID) else {
            throw JournalError.revisionNotFound
        }
        created.isRestore = true
        try context.save()
        return record
    }

    public func moveToTrash(
        entryID: UUID,
        deviceID: String,
        at date: Date = .now
    ) throws {
        guard let entity = try findEntry(id: entryID) else {
            throw JournalError.entryNotFound
        }
        entity.deletedAt = date
        entity.updatedAt = date
        entity.modifiedByDeviceID = deviceID
        try context.save()
    }

    public func restoreFromTrash(
        entryID: UUID,
        deviceID: String,
        at date: Date = .now
    ) throws {
        guard let entity = try findEntry(id: entryID) else {
            throw JournalError.entryNotFound
        }
        let snapshot = try map(entity).draft
        _ = try save(snapshot, deviceID: deviceID, at: date)
    }

    public func classificationRules() throws -> [ClassificationRuleRecord] {
        let descriptor = FetchDescriptor<ClassificationRuleEntity>(
            sortBy: [
                SortDescriptor(\ClassificationRuleEntity.priority, order: .reverse),
                SortDescriptor(\ClassificationRuleEntity.stableID),
            ]
        )
        return try context.fetch(descriptor).compactMap { entity in
            guard let source = ClassificationSource(rawValue: entity.sourceRaw),
                  let target = JournalKind(rawValue: entity.targetKindRaw) else {
                return nil
            }
            return ClassificationRuleRecord(
                id: entity.stableID,
                source: source,
                value: entity.value,
                targetKind: target,
                priority: entity.priority,
                updatedAt: entity.updatedAt
            )
        }
    }

    public func saveClassificationRule(_ rule: ClassificationRuleRecord) throws {
        let identifier = rule.id
        var descriptor = FetchDescriptor<ClassificationRuleEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        let entity = try context.fetch(descriptor).first ?? ClassificationRuleEntity()
        entity.stableID = rule.id
        entity.sourceRaw = rule.source.rawValue
        entity.value = rule.value
        entity.targetKindRaw = rule.targetKind.rawValue
        entity.priority = rule.priority
        entity.updatedAt = rule.updatedAt
        if entity.modelContext == nil { context.insert(entity) }
        try context.save()
    }

    public func deleteClassificationRule(id: UUID) throws {
        let identifier = id
        var descriptor = FetchDescriptor<ClassificationRuleEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        if let entity = try context.fetch(descriptor).first {
            context.delete(entity)
            try context.save()
        }
    }

    public func importRevision(_ revision: EntryRevisionRecord) throws {
        guard try findRevision(id: revision.id) == nil else { return }
        let entity = EntryRevisionEntity()
        entity.stableID = revision.id
        entity.entryID = revision.entryID
        entity.parentRevisionID = revision.parentRevisionID
        entity.snapshotData = try encoder.encode(revision.snapshot)
        entity.createdAt = revision.createdAt
        entity.deviceID = revision.deviceID
        entity.isRestore = revision.isRestore
        context.insert(entity)
        try context.save()
    }

    public func saveRestoreEpoch(_ epoch: RestoreEpochRecord) throws {
        let identifier = epoch.id
        var descriptor = FetchDescriptor<RestoreEpochEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return }
        let entity = RestoreEpochEntity()
        entity.stableID = epoch.id
        entity.createdAt = epoch.createdAt
        entity.modeRaw = epoch.mode.rawValue
        context.insert(entity)
        try context.save()
    }

    public func allAttachments() throws -> [(AttachmentRecord, Data?)] {
        let descriptor = FetchDescriptor<AttachmentEntity>()
        return try context.fetch(descriptor).map { entity in
            let record = AttachmentRecord(
                id: entity.stableID,
                entryID: entity.entryID,
                originalName: entity.originalName,
                mimeType: entity.mimeType,
                checksum: entity.checksum,
                byteCount: entity.byteCount,
                state: AttachmentTransferState(rawValue: entity.stateRaw) ?? .failed,
                updatedAt: entity.updatedAt,
                deletedAt: entity.deletedAt
            )
            return (record, entity.binary)
        }
    }

    public func saveAttachment(_ record: AttachmentRecord, binary: Data?) throws {
        let identifier = record.id
        var descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        let entity = try context.fetch(descriptor).first ?? AttachmentEntity()
        entity.stableID = record.id
        entity.entryID = record.entryID
        entity.originalName = record.originalName
        entity.mimeType = record.mimeType
        entity.checksum = record.checksum
        entity.byteCount = record.byteCount
        entity.stateRaw = record.state.rawValue
        entity.updatedAt = record.updatedAt
        entity.deletedAt = record.deletedAt
        if let binary { entity.binary = binary }
        if entity.modelContext == nil { context.insert(entity) }
        try context.save()
    }

    private func findEntry(id: UUID) throws -> JournalEntryEntity? {
        let identifier = id
        var descriptor = FetchDescriptor<JournalEntryEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func findRevision(id: UUID) throws -> EntryRevisionEntity? {
        let identifier = id
        var descriptor = FetchDescriptor<EntryRevisionEntity>(
            predicate: #Predicate { revision in revision.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func map(_ entity: JournalEntryEntity) throws -> JournalEntryRecord {
        let kind = JournalKind(rawValue: entity.kindRaw) ?? .unclassified
        let tags = try entity.tagsData.map { try decoder.decode([String].self, from: $0) } ?? []
        let details = try entity.detailsData.map {
            try decoder.decode(EntryDetails.self, from: $0)
        } ?? EntryDetails()
        return JournalEntryRecord(
            id: entity.stableID,
            kind: kind,
            title: entity.title,
            body: entity.body,
            occurredAt: entity.occurredAt,
            originalTimeZone: entity.originalTimeZone,
            tags: tags,
            isStarred: entity.isStarred,
            isPinned: entity.isPinned,
            details: details,
            sourceUUID: entity.sourceUUID,
            sourceMetadata: entity.sourceMetadata,
            currentRevisionID: entity.currentRevisionID,
            updatedAt: entity.updatedAt,
            modifiedByDeviceID: entity.modifiedByDeviceID,
            deletedAt: entity.deletedAt
        )
    }

    private func map(_ entity: EntryRevisionEntity) throws -> EntryRevisionRecord {
        guard let data = entity.snapshotData else {
            throw JournalError.persistence("revision snapshot이 없습니다.")
        }
        return EntryRevisionRecord(
            id: entity.stableID,
            entryID: entity.entryID,
            parentRevisionID: entity.parentRevisionID,
            snapshot: try decoder.decode(JournalEntryDraft.self, from: data),
            createdAt: entity.createdAt,
            deviceID: entity.deviceID,
            isRestore: entity.isRestore
        )
    }
}
#endif
