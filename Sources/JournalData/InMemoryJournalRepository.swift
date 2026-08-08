import Foundation
import JournalDomain

@MainActor
public final class InMemoryJournalRepository:
    JournalRepository,
    AttachmentRepository,
    BackupRestoreRepository
{
    private struct StoredAttachmentSnapshot: Codable {
        var record: AttachmentRecord
        var binary: Data?
    }

    private struct PersistenceSnapshot: Codable {
        var entries: [JournalEntryRecord]
        var revisions: [EntryRevisionRecord]
        var rules: [ClassificationRuleRecord]
        var attachments: [StoredAttachmentSnapshot]
        var restoreEpochs: [RestoreEpochRecord]
    }

    private var entries: [UUID: JournalEntryRecord] = [:]
    private var revisionStorage: [UUID: [EntryRevisionRecord]] = [:]
    private var rules: [UUID: ClassificationRuleRecord] = [:]
    private var attachmentStorage: [UUID: (AttachmentRecord, Data?)] = [:]
    private var restoreEpochs: [RestoreEpochRecord] = []
    private let storageURL: URL?

    public init() {
        storageURL = nil
    }

    public init(storageURL: URL) throws {
        self.storageURL = storageURL
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        let snapshot = try JSONDecoder().decode(
            PersistenceSnapshot.self,
            from: Data(contentsOf: storageURL)
        )
        entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        revisionStorage = Dictionary(grouping: snapshot.revisions, by: \.entryID)
        rules = Dictionary(uniqueKeysWithValues: snapshot.rules.map { ($0.id, $0) })
        attachmentStorage = Dictionary(uniqueKeysWithValues: snapshot.attachments.map {
            ($0.record.id, ($0.record, $0.binary))
        })
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
        let nextCursor = hasMore ? values.last.map {
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
        let validated = try draft.validated(manual: draft.sourceUUID == nil)
        if let sourceUUID = validated.sourceUUID,
           let duplicate = try entry(sourceUUID: sourceUUID),
           duplicate.id != validated.id {
            throw JournalError.duplicateSource(sourceUUID)
        }
        let entryID = validated.id
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
            modifiedByDeviceID: deviceID
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
              var latest = storedRevisions.last else {
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
    }

    public func classificationRules() throws -> [ClassificationRuleRecord] {
        rules.values.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func saveClassificationRule(_ rule: ClassificationRuleRecord) throws {
        rules[rule.id] = rule
        try persist()
    }

    public func deleteClassificationRule(id: UUID) throws {
        rules[id] = nil
        try persist()
    }

    public func importRevision(_ revision: EntryRevisionRecord) throws {
        guard !(revisionStorage[revision.entryID] ?? []).contains(where: {
            $0.id == revision.id
        }) else { return }
        revisionStorage[revision.entryID, default: []].append(revision)
        try persist()
    }

    public func saveRestoreEpoch(_ epoch: RestoreEpochRecord) throws {
        if !restoreEpochs.contains(where: { $0.id == epoch.id }) {
            restoreEpochs.append(epoch)
            try persist()
        }
    }

    public func allRestoreEpochs() -> [RestoreEpochRecord] {
        restoreEpochs
    }

    public func saveAttachment(_ record: AttachmentRecord, binary: Data?) throws {
        attachmentStorage[record.id] = (record, binary)
        try persist()
    }

    public func allAttachments() throws -> [(AttachmentRecord, Data?)] {
        attachmentStorage.values.map { $0 }
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
            attachments: attachmentStorage.values.map {
                StoredAttachmentSnapshot(record: $0.0, binary: $0.1)
            }.sorted { $0.record.id.uuidString < $1.record.id.uuidString },
            restoreEpochs: restoreEpochs.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: storageURL, options: [.atomic])
    }
}
