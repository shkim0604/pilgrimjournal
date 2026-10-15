import Foundation
import JournalDomain

@MainActor
public final class InMemoryJournalRepository:
    JournalRepository,
    AttachmentRepository,
    BackupRestoreRepository
{
    private struct PersistenceSnapshot: Codable {
        var entries: [JournalEntryRecord]
        var revisions: [EntryRevisionRecord]
        var rules: [ClassificationRuleRecord]
        var attachments: [StoredAttachment]
        var restoreEpochs: [RestoreEpochRecord]
    }

    private var entries: [UUID: JournalEntryRecord] = [:]
    private var revisionStorage: [UUID: [EntryRevisionRecord]] = [:]
    private var rules: [UUID: ClassificationRuleRecord] = [:]
    private var attachmentStorage: [UUID: StoredAttachment] = [:]
    private var restoreEpochs: [RestoreEpochRecord] = []
    private let storageURL: URL?

    public init() {
        storageURL = nil
    }

    /// A repository that loads from, and saves every change back to, a JSON
    /// snapshot at `url`. Used by the local-only adapter outside SwiftData
    /// builds; `init()` keeps everything in memory only.
    public init(persistingTo url: URL) throws {
        storageURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let snapshot = try JSONDecoder().decode(
            PersistenceSnapshot.self,
            from: Data(contentsOf: url)
        )
        entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        revisionStorage = Dictionary(grouping: snapshot.revisions, by: \.entryID)
        rules = Dictionary(uniqueKeysWithValues: snapshot.rules.map { ($0.id, $0) })
        attachmentStorage = Dictionary(
            uniqueKeysWithValues: snapshot.attachments.map { ($0.record.id, $0) }
        )
        restoreEpochs = snapshot.restoreEpochs
    }

    public func list(
        kind: JournalKind?,
        includeDeleted: Bool,
        limit: Int
    ) throws -> [JournalEntryRecord] {
        entries.values
            .filter { includeDeleted || !$0.isDeleted }
            .filter { kind == nil || $0.kind == kind }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit)
            .map { $0 }
    }

    public func page(
        kind: JournalKind?,
        includeDeleted: Bool,
        after cursor: JournalTimelineCursor?,
        limit: Int
    ) throws -> JournalTimelinePage {
        let pageSize = max(1, limit)
        let candidates = entries.values
            .filter { includeDeleted || !$0.isDeleted }
            .filter { kind == nil || $0.kind == kind }
            .filter { entry in
                guard let cursor else { return true }
                if entry.occurredAt != cursor.occurredAt {
                    return entry.occurredAt < cursor.occurredAt
                }
                return entry.id.uuidString > cursor.entryID.uuidString
            }
            .sorted {
                if $0.occurredAt != $1.occurredAt {
                    return $0.occurredAt > $1.occurredAt
                }
                return $0.id.uuidString < $1.id.uuidString
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

    public func entry(id: UUID) throws -> JournalEntryRecord? { entries[id] }

    public func entry(sourceUUID: String) throws -> JournalEntryRecord? {
        entries.values.first {
            $0.sourceUUID?.caseInsensitiveCompare(sourceUUID) == .orderedSame
        }
    }

    public func save(
        _ draft: JournalEntryDraft,
        deviceID: String,
        at date: Date
    ) throws -> JournalEntryRecord {
        // Only creating a new hand-written entry must pick a concrete kind; an existing
        // entry may be moved to 미분류 (e.g. when its kind is deleted).
        let isNewManualEntry =
            try draft.sourceUUID == nil && (draft.id.map { try entry(id: $0) == nil } ?? true)
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
        let previous = entries[entryID]
        let revision = EntryRevisionRecord(
            entryID: entryID,
            parentRevisionID: previous?.currentRevisionID,
            snapshot: validated,
            createdAt: date,
            deviceID: deviceID
        )
        let record = JournalEntryRecord(
            id: entryID,
            kind: validated.kind,
            title: validated.title,
            body: validated.body,
            occurredAt: validated.occurredAt,
            originalTimeZone: validated.originalTimeZone,
            tags: validated.tags,
            isStarred: validated.isStarred,
            isPinned: validated.isPinned,
            details: validated.details,
            sourceUUID: validated.sourceUUID,
            sourceMetadata: validated.sourceMetadata,
            currentRevisionID: revision.id,
            updatedAt: date,
            modifiedByDeviceID: deviceID,
            deletedAt: previous?.deletedAt
        )
        entries[entryID] = record
        revisionStorage[entryID, default: []].append(revision)
        try persist()
        return record
    }

    public func revisions(entryID: UUID) throws -> [EntryRevisionRecord] {
        (revisionStorage[entryID] ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    public func restore(
        entryID: UUID,
        revisionID: UUID,
        deviceID: String,
        at date: Date
    ) throws -> JournalEntryRecord {
        guard let selected = revisionStorage[entryID]?.first(where: { $0.id == revisionID }) else {
            throw JournalError.revisionNotFound
        }
        var draft = selected.snapshot
        draft.id = entryID
        let restored = try save(draft, deviceID: deviceID, at: date)
        guard var storedRevisions = revisionStorage[entryID],
            var latest = storedRevisions.last
        else {
            throw JournalError.revisionNotFound
        }
        latest.isRestore = true
        storedRevisions[storedRevisions.count - 1] = latest
        revisionStorage[entryID] = storedRevisions
        try persist()
        return restored
    }

    public func moveToTrash(
        entryID: UUID,
        deviceID: String,
        at date: Date
    ) throws {
        guard var entry = entries[entryID] else { throw JournalError.entryNotFound }
        entry.deletedAt = date
        entry.updatedAt = date
        entry.modifiedByDeviceID = deviceID
        entries[entryID] = entry
        try persist()
    }

    public func restoreFromTrash(
        entryID: UUID,
        deviceID: String,
        at date: Date
    ) throws {
        guard let entry = entries[entryID] else { throw JournalError.entryNotFound }
        _ = try save(entry.draft, deviceID: deviceID, at: date)
        entries[entryID]?.deletedAt = nil
        entries[entryID]?.updatedAt = date
        entries[entryID]?.modifiedByDeviceID = deviceID
        try persist()
    }

    public func purgeEntries(ids: Set<UUID>) throws -> JournalPurgeSummary {
        guard !ids.isEmpty else { return .empty }
        let purgedIDs = Set(entries.keys).intersection(ids)
        guard !purgedIDs.isEmpty else { return .empty }
        // Validate-all-then-delete, matching SwiftDataJournalRepository.
        guard purgedIDs.allSatisfy({ entries[$0]?.isDeleted == true }) else {
            throw JournalError.persistence("휴지통에 있는 기록만 영구 삭제할 수 있습니다.")
        }

        let originalEntries = entries
        let originalRevisions = revisionStorage
        let originalAttachments = attachmentStorage

        let purgedSourceUUIDs = Set(purgedIDs.compactMap { entries[$0]?.sourceUUID })
        let removedRevisionCount = purgedIDs.reduce(0) { $0 + (revisionStorage[$1]?.count ?? 0) }
        let purgedAttachmentIDs = attachmentStorage.values
            .filter { purgedIDs.contains($0.record.entryID) }
            .map(\.record.id)
        let survivingChecksums = Set(
            attachmentStorage.values
                .filter { !purgedIDs.contains($0.record.entryID) }
                .map { $0.record.checksum }
        )
        let releasedChecksums = Set(
            attachmentStorage.values
                .filter { purgedIDs.contains($0.record.entryID) }
                .map { $0.record.checksum }
        ).subtracting(survivingChecksums)

        for id in purgedIDs {
            entries[id] = nil
            revisionStorage[id] = nil
        }
        for attachmentID in purgedAttachmentIDs {
            attachmentStorage[attachmentID] = nil
        }

        do {
            try persist()
        } catch {
            entries = originalEntries
            revisionStorage = originalRevisions
            attachmentStorage = originalAttachments
            try? persist()
            throw error
        }

        return JournalPurgeSummary(
            purgedEntryIDs: purgedIDs,
            removedRevisionCount: removedRevisionCount,
            removedAttachmentIDs: Set(purgedAttachmentIDs),
            releasedChecksums: releasedChecksums,
            purgedSourceUUIDs: purgedSourceUUIDs
        )
    }

    public func classificationRules() throws -> [ClassificationRuleRecord] {
        rules.values.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func saveClassificationRule(_ rule: ClassificationRuleRecord) throws {
        if let existing = rules[rule.id] {
            rules[rule.id] = ClassificationRuleResolver().winner(existing, rule)
        } else {
            rules[rule.id] = rule
        }
        try persist()
    }

    public func deleteClassificationRule(id: UUID) throws {
        rules[id] = nil
        try persist()
    }

    public func importRevision(_ revision: EntryRevisionRecord) throws {
        guard
            !(revisionStorage[revision.entryID] ?? []).contains(where: {
                $0.id == revision.id
            })
        else { return }
        revisionStorage[revision.entryID, default: []].append(revision)
        try persist()
    }

    public func saveRestoreEpoch(_ epoch: RestoreEpochRecord) throws {
        if !restoreEpochs.contains(where: { $0.id == epoch.id }) {
            restoreEpochs.append(epoch)
            try persist()
        }
    }

    package func allRestoreEpochs() -> [RestoreEpochRecord] {
        restoreEpochs
    }

    public func saveAttachment(_ record: AttachmentRecord, binary: Data?) throws {
        attachmentStorage[record.id] = StoredAttachment(record: record, binary: binary)
        try persist()
    }

    public func allAttachments() throws -> [StoredAttachment] {
        Array(attachmentStorage.values)
    }

    public func attachment(id: UUID) throws -> StoredAttachment? {
        attachmentStorage[id]
    }

    public func attachmentChecksum(id: UUID) throws -> String? {
        attachmentStorage[id]?.record.checksum
    }

    public func attachmentChecksums() throws -> Set<String> {
        Set(attachmentStorage.values.map { $0.record.checksum })
    }

    public func attachments(forEntry entryID: UUID) throws -> [AttachmentRecord] {
        attachmentStorage.values.map(\.record).filter { $0.entryID == entryID }
    }

    public func attachments(
        inStates states: Set<AttachmentTransferState>
    ) throws -> [StoredAttachment] {
        attachmentStorage.values.filter { states.contains($0.record.state) }
    }

    @discardableResult
    public func updateAttachmentState(
        id: UUID, state: AttachmentTransferState, updatedAt: Date
    ) throws -> Bool {
        guard var entry = attachmentStorage[id] else { return false }
        entry.record.state = state
        entry.record.updatedAt = updatedAt
        attachmentStorage[id] = entry
        try persist()
        return true
    }

    @discardableResult
    public func deleteAttachment(id: UUID) throws -> String? {
        guard let removed = attachmentStorage[id] else { return nil }
        attachmentStorage[id] = nil
        do {
            try persist()
        } catch {
            attachmentStorage[id] = removed
            throw error
        }
        return removed.record.checksum
    }

    public func performRestoreTransaction(
        _ operation: () throws -> Void
    ) throws {
        let originalEntries = entries
        let originalRevisions = revisionStorage
        let originalRules = rules
        let originalAttachments = attachmentStorage
        let originalRestoreEpochs = restoreEpochs
        do {
            try operation()
        } catch {
            entries = originalEntries
            revisionStorage = originalRevisions
            rules = originalRules
            attachmentStorage = originalAttachments
            restoreEpochs = originalRestoreEpochs
            try? persist()
            throw error
        }
    }

    private func persist() throws {
        guard let storageURL else { return }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = PersistenceSnapshot(
            entries: entries.values.sorted { $0.id.uuidString < $1.id.uuidString },
            revisions: revisionStorage.values.flatMap { $0 }.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            rules: rules.values.sorted { $0.id.uuidString < $1.id.uuidString },
            attachments: attachmentStorage.values.sorted {
                $0.record.id.uuidString < $1.record.id.uuidString
            },
            restoreEpochs: restoreEpochs.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: storageURL, options: [.atomic])
    }
}
