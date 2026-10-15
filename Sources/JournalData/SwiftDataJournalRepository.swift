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
    private var isPerformingRestoreTransaction = false

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
                    entity.stableID.uuidString <= cursor.entryID.uuidString
                {
                    return nil
                }
            }
            return try map(entity)
        }
        let values = Array(candidates.prefix(pageSize))
        let hasMore = candidates.count > values.count
        let nextCursor =
            hasMore
            ? values.last.map {
                JournalTimelineCursor(occurredAt: $0.occurredAt, entryID: $0.id)
            } : nil
        return JournalTimelinePage(entries: values, nextCursor: nextCursor)
    }

    public func entry(id: UUID) throws -> JournalEntryRecord? {
        try findEntry(id: id).map(map)
    }

    public func entry(sourceUUID: String) throws -> JournalEntryRecord? {
        let normalized = sourceUUID.lowercased()
        let descriptor = FetchDescriptor<JournalEntryEntity>(
            predicate: #Predicate { entity in
                entity.sourceUUID != nil
            }
        )
        // Deliberately no fetchLimit: this backs duplicate-import detection
        // and cross-device merge matching, so a cap would silently miss
        // matches past it once more than the limit have been imported.
        return try context.fetch(descriptor)
            .first(where: { $0.sourceUUID?.lowercased() == normalized })
            .map(map)
    }

    public func save(
        _ draft: JournalEntryDraft,
        deviceID: String,
        at date: Date = .now
    ) throws -> JournalEntryRecord {
        // Only creating a new hand-written entry (no ID yet) must pick a concrete
        // kind. A draft with an ID is an existing entry — possibly moved to 미분류
        // when its kind was deleted — even when this store has not seen it yet
        // (backup restore, local-to-iCloud migration).
        let isNewManualEntry = draft.sourceUUID == nil && draft.id == nil
        let validated = try draft.validated(manual: isNewManualEntry)
        if let sourceUUID = validated.sourceUUID,
            let duplicate = try entry(sourceUUID: sourceUUID),
            duplicate.id != validated.id
        {
            throw JournalError.duplicateSource(sourceUUID)
        }

        let entryID =
            validated.id
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
        if entity.modelContext == nil { context.insert(entity) }

        let revision = EntryRevisionEntity()
        revision.stableID = revisionID
        revision.entryID = entryID
        revision.parentRevisionID = parentRevisionID
        revision.snapshotData = try encoder.encode(validated)
        revision.createdAt = date
        revision.deviceID = deviceID
        context.insert(revision)
        try saveIfNeeded()
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
            let snapshotData = revision.snapshotData
        else {
            throw JournalError.revisionNotFound
        }
        var draft = try decoder.decode(JournalEntryDraft.self, from: snapshotData)
        draft.id = entryID
        let record = try save(draft, deviceID: deviceID, at: date)
        guard let created = try findRevision(id: record.currentRevisionID) else {
            throw JournalError.revisionNotFound
        }
        created.isRestore = true
        try saveIfNeeded()
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
        try saveIfNeeded()
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
        entity.deletedAt = nil
        entity.updatedAt = date
        entity.modifiedByDeviceID = deviceID
        try saveIfNeeded()
    }

    public func purgeEntries(ids: Set<UUID>) throws -> JournalPurgeSummary {
        guard !ids.isEmpty else { return .empty }
        let idList = Array(ids)
        let entryDescriptor = FetchDescriptor<JournalEntryEntity>(
            predicate: #Predicate { entity in idList.contains(entity.stableID) }
        )
        // Deliberately no fetchLimit: a limit here would silently orphan
        // rows past it instead of purging them.
        let entities = try context.fetch(entryDescriptor)
        guard !entities.isEmpty else { return .empty }
        // Validate-all-then-delete: if any requested id isn't actually in
        // the trash, throw before deleting anything, so a caller bug can
        // never turn into "some live entries got deleted too". IDs that no
        // longer exist at all are simply absent from `entities` and are
        // skipped — repeated purge calls are idempotent.
        guard entities.allSatisfy({ $0.deletedAt != nil }) else {
            throw JournalError.persistence(
                String(localized: "휴지통에 있는 기록만 영구 삭제할 수 있습니다.", bundle: .module))
        }

        let purgedIDs = Set(entities.map(\.stableID))
        let purgedIDList = Array(purgedIDs)
        let purgedSourceUUIDs = Set(entities.compactMap(\.sourceUUID))

        let revisionDescriptor = FetchDescriptor<EntryRevisionEntity>(
            predicate: #Predicate { revision in purgedIDList.contains(revision.entryID) }
        )
        let revisions = try context.fetch(revisionDescriptor)

        // No SwiftData relationship links attachments to their entry, so
        // there's no cascade — fetch every attachment row (never `.binary`,
        // to avoid faulting external-storage blobs) and split it by hand.
        let allAttachments = try context.fetch(FetchDescriptor<AttachmentEntity>())
        let purgedAttachments = allAttachments.filter { purgedIDs.contains($0.entryID) }
        let survivingChecksums = Set(
            allAttachments
                .filter { !purgedIDs.contains($0.entryID) }
                .map(\.checksum)
        )
        let releasedChecksums = Set(purgedAttachments.map(\.checksum))
            .subtracting(survivingChecksums)
        let removedAttachmentIDs = Set(purgedAttachments.map(\.stableID))

        // Children first: if the process dies mid-transaction, the worst
        // surviving state is a trashed entry with no revisions/attachments
        // (visible, re-purgeable), not orphaned rows nothing can reach.
        for revision in revisions { context.delete(revision) }
        for attachment in purgedAttachments { context.delete(attachment) }
        for entity in entities { context.delete(entity) }

        do {
            try saveIfNeeded()
        } catch {
            context.rollback()
            throw error
        }

        return JournalPurgeSummary(
            purgedEntryIDs: purgedIDs,
            removedRevisionCount: revisions.count,
            removedAttachmentIDs: removedAttachmentIDs,
            releasedChecksums: releasedChecksums,
            purgedSourceUUIDs: purgedSourceUUIDs
        )
    }

    public func classificationRules() throws -> [ClassificationRuleRecord] {
        let descriptor = FetchDescriptor<ClassificationRuleEntity>(
            sortBy: [
                SortDescriptor(\ClassificationRuleEntity.priority, order: .reverse),
                SortDescriptor(\ClassificationRuleEntity.stableID),
            ]
        )
        let resolver = ClassificationRuleResolver()
        let resolved = try context.fetch(descriptor).compactMap(mapRule).reduce(
            into: [UUID: ClassificationRuleRecord]()
        ) { winners, rule in
            if let existing = winners[rule.id] {
                winners[rule.id] = resolver.winner(existing, rule)
            } else {
                winners[rule.id] = rule
            }
        }
        return resolved.values.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func saveClassificationRule(_ rule: ClassificationRuleRecord) throws {
        let identifier = rule.id
        let descriptor = FetchDescriptor<ClassificationRuleEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        let existingEntities = try context.fetch(descriptor)
        let resolver = ClassificationRuleResolver()
        let winner = existingEntities.compactMap(mapRule).reduce(rule) {
            resolver.winner($0, $1)
        }
        let targets =
            existingEntities.isEmpty
            ? [ClassificationRuleEntity()]
            : existingEntities
        for entity in targets {
            entity.stableID = winner.id
            entity.sourceRaw = winner.source.rawValue
            entity.value = winner.value
            entity.targetKindRaw = winner.targetKind.rawValue
            entity.priority = winner.priority
            entity.updatedAt = winner.updatedAt
            if entity.modelContext == nil { context.insert(entity) }
        }
        try saveIfNeeded()
    }

    public func deleteClassificationRule(id: UUID) throws {
        let identifier = id
        let descriptor = FetchDescriptor<ClassificationRuleEntity>(
            predicate: #Predicate { entity in entity.stableID == identifier }
        )
        for entity in try context.fetch(descriptor) {
            context.delete(entity)
        }
        try saveIfNeeded()
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
        try saveIfNeeded()
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
        try saveIfNeeded()
    }

    public func allAttachments() throws -> [StoredAttachment] {
        let descriptor = FetchDescriptor<AttachmentEntity>()
        return try context.fetch(descriptor).map { entity in
            StoredAttachment(record: attachmentRecord(entity), binary: entity.binary)
        }
    }

    public func attachment(id: UUID) throws -> StoredAttachment? {
        var descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.stableID == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else { return nil }
        return StoredAttachment(record: attachmentRecord(entity), binary: entity.binary)
    }

    public func attachmentChecksum(id: UUID) throws -> String? {
        var descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.stableID == id }
        )
        descriptor.fetchLimit = 1
        // Never touches `.binary` — see the protocol doc comment.
        return try context.fetch(descriptor).first?.checksum
    }

    public func attachmentChecksums() throws -> Set<String> {
        // A bare fetch of only what's needed to compute references — never
        // touches `.binary`, unlike `allAttachments()`.
        Set(try context.fetch(FetchDescriptor<AttachmentEntity>()).map(\.checksum))
    }

    public func attachments(forEntry entryID: UUID) throws -> [AttachmentRecord] {
        let descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.entryID == entryID }
        )
        // Deliberately never touches `entity.binary` — see the protocol doc
        // comment. This is the metadata-only, entryID-scoped counterpart to
        // `attachment(id:)`.
        return try context.fetch(descriptor).map { entity in
            attachmentRecord(entity)
        }
    }

    public func attachments(
        inStates states: Set<AttachmentTransferState>
    ) throws -> [StoredAttachment] {
        let rawStates = states.map(\.rawValue)
        let descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in rawStates.contains(entity.stateRaw) }
        )
        return try context.fetch(descriptor).map { entity in
            StoredAttachment(record: attachmentRecord(entity), binary: entity.binary)
        }
    }

    /// Metadata only. Must never read `entity.binary`: callers such as
    /// `attachments(forEntry:)` rely on not faulting external-storage blobs.
    private func attachmentRecord(_ entity: AttachmentEntity) -> AttachmentRecord {
        AttachmentRecord(
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
    }

    @discardableResult
    public func updateAttachmentState(
        id: UUID, state: AttachmentTransferState, updatedAt: Date
    ) throws -> Bool {
        var descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.stableID == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else { return false }
        // Never touches `.binary` — that's the whole point versus routing
        // this through `saveAttachment(_:binary:)`.
        entity.stateRaw = state.rawValue
        entity.updatedAt = updatedAt
        try saveIfNeeded()
        return true
    }

    @discardableResult
    public func deleteAttachment(id: UUID) throws -> String? {
        var descriptor = FetchDescriptor<AttachmentEntity>(
            predicate: #Predicate { entity in entity.stableID == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else { return nil }
        let checksum = entity.checksum
        context.delete(entity)
        try saveIfNeeded()
        return checksum
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
        try saveIfNeeded()
    }

    public func performRestoreTransaction(
        _ operation: () throws -> Void
    ) throws {
        guard !isPerformingRestoreTransaction else {
            try operation()
            return
        }
        isPerformingRestoreTransaction = true
        defer { isPerformingRestoreTransaction = false }
        do {
            try operation()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func saveIfNeeded() throws {
        if !isPerformingRestoreTransaction {
            try context.save()
        }
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

    private func mapRule(
        _ entity: ClassificationRuleEntity
    ) -> ClassificationRuleRecord? {
        guard let source = ClassificationSource(rawValue: entity.sourceRaw),
            let target = JournalKind(rawValue: entity.targetKindRaw)
        else {
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

    private func map(_ entity: JournalEntryEntity) throws -> JournalEntryRecord {
        let kind = entity.kindRaw.isEmpty ? .unclassified : JournalKind(id: entity.kindRaw)
        let tags = try entity.tagsData.map { try decoder.decode([String].self, from: $0) } ?? []
        let details =
            try entity.detailsData.map {
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
            throw JournalError.persistence(
                String(localized: "revision snapshot이 없습니다.", bundle: .module))
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
