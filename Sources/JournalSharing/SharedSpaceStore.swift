import CloudKit
import Foundation
import JournalDomain

/// The device's copy of every shared space: one entry cache per space plus the sync
/// bookkeeping CloudKit needs (each record's server system fields, the last version both
/// sides agreed on for merging, and whether local edits are still unsent).
///
/// Local edits go through `save(_:kind:in:)`, which writes the cache and queues the entry
/// and its new revision for upload. Remote changes arrive through `SharedSyncStore`.
@MainActor
public final class SharedSpaceStore: SharedSyncStore {
    public private(set) var spaces: [SharedSpaceRecord] = []
    /// Called with record IDs to upload or delete; wired to `SharedSyncEngineHost`.
    public var onEnqueue: ((_ saves: [CKRecord.ID], _ deletes: [CKRecord.ID]) -> Void)?
    /// Called after any change to spaces or their entries, for the UI to reload.
    public var onChange: (() -> Void)?

    private let metadataURL: URL
    private let deviceID: String
    private let provider: SharedEntryCacheProvider
    private var metadata: Metadata

    public init(directory: URL, deviceID: String, provider: SharedEntryCacheProvider) throws {
        metadataURL = directory.appending(path: "SharedSync.json")
        self.deviceID = deviceID
        self.provider = provider
        if let data = try? Data(contentsOf: metadataURL) {
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
        } else {
            metadata = Metadata()
        }
        spaces = metadata.spaces.map(\.space)
    }

    // MARK: Spaces

    public func cache(for spaceID: UUID) throws -> any SharedEntryCache {
        guard let state = metadata.spaces.first(where: { $0.space.id == spaceID }) else {
            throw JournalError.entryNotFound
        }
        return try provider.cache(for: state.space)
    }

    public func zoneID(for spaceID: UUID) -> CKRecordZone.ID? {
        metadata.spaces.first { $0.space.id == spaceID }.map {
            SharedRecordMapper.zoneID(for: $0.space, ownerName: $0.zoneOwnerName)
        }
    }

    /// Records a space after its zone and share were created or accepted.
    public func addSpace(
        _ space: SharedSpaceRecord, zoneOwnerName: String = CKCurrentUserDefaultName
    ) {
        if let index = metadata.spaces.firstIndex(where: { $0.space.id == space.id }) {
            metadata.spaces[index].space = space
            metadata.spaces[index].zoneOwnerName = zoneOwnerName
        } else {
            metadata.spaces.append(SpaceState(space: space, zoneOwnerName: zoneOwnerName))
        }
        commit()
    }

    /// The zones the private-database engine should fetch: only spaces this user owns,
    /// never the journal's Core Data zone.
    public var ownedZoneIDs: [CKRecordZone.ID] {
        metadata.spaces.filter { $0.zoneOwnerName == CKCurrentUserDefaultName }.map {
            SharedRecordMapper.zoneID(for: $0.space)
        }
    }

    // MARK: Local edits

    @discardableResult
    public func save(
        _ draft: JournalEntryDraft,
        kind: SharedKindSnapshot,
        in spaceID: UUID,
        at date: Date = .now
    ) throws -> JournalEntryRecord {
        guard let zoneID = zoneID(for: spaceID) else { throw JournalError.entryNotFound }
        let saved = try cache(for: spaceID).save(draft, deviceID: deviceID, at: date)
        markUnsent(saved, kind: kind, zoneID: zoneID)
        commit()
        return saved
    }

    public func moveToTrash(entryID: UUID, in spaceID: UUID, at date: Date = .now) throws {
        guard let zoneID = zoneID(for: spaceID) else { throw JournalError.entryNotFound }
        let cache = try cache(for: spaceID)
        try cache.moveToTrash(entryID: entryID, deviceID: deviceID, at: date)
        if let entry = try cache.entry(id: entryID) {
            metadata.records[
                entry.id.uuidString, default: RecordState(type: .entry, zoneName: zoneID.zoneName)
            ]
            .hasUnsentChanges = true
            onEnqueue?([SharedRecordMapper.recordID(for: entry.id, in: zoneID)], [])
        }
        commit()
    }

    private func markUnsent(
        _ entry: JournalEntryRecord, kind: SharedKindSnapshot, zoneID: CKRecordZone.ID
    ) {
        var entryState = metadata.records[entry.id.uuidString] ?? RecordState(type: .entry)
        entryState.hasUnsentChanges = true
        entryState.kind = kind
        entryState.zoneName = zoneID.zoneName
        metadata.records[entry.id.uuidString] = entryState
        metadata.records[entry.currentRevisionID.uuidString] = RecordState(
            type: .revision(entryID: entry.id), hasUnsentChanges: true, zoneName: zoneID.zoneName)
        onEnqueue?(
            [
                SharedRecordMapper.recordID(for: entry.id, in: zoneID),
                SharedRecordMapper.recordID(for: entry.currentRevisionID, in: zoneID),
            ],
            []
        )
    }

    // MARK: SharedSyncStore

    public func stateSerialization(for scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization?
    {
        scope == .private ? metadata.privateState : metadata.sharedState
    }

    public func saveStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization,
        for scope: CKDatabase.Scope
    ) {
        if scope == .private {
            metadata.privateState = serialization
        } else {
            metadata.sharedState = serialization
        }
        persist()
    }

    public func recordToSave(_ recordID: CKRecord.ID) -> CKRecord? {
        guard let state = metadata.records[recordID.recordName],
            let space = space(for: recordID.zoneID),
            let cache = try? provider.cache(for: space),
            let id = UUID(uuidString: recordID.recordName)
        else { return nil }

        switch state.type {
        case .entry:
            guard let entry = try? cache.entry(id: id) else { return nil }
            let record = serverRecord(state, type: SharedRecordType.entry, id: recordID)
            let kind =
                state.kind
                ?? SharedKindSnapshot(
                    kind: entry.kind, name: entry.kind.fallbackName, colorToken: .stone,
                    iconToken: "tag")
            SharedRecordMapper.write(SharedEntryPayload(entry: entry, kind: kind), to: record)
            return record
        case .revision(let entryID):
            guard
                let revision = try? cache.revisions(entryID: entryID).first(where: { $0.id == id })
            else { return nil }
            let record = serverRecord(state, type: SharedRecordType.revision, id: recordID)
            do {
                try SharedRecordMapper.write(revision, to: record)
            } catch {
                return nil
            }
            return record
        }
    }

    public func applyFetched(_ record: CKRecord) -> Bool {
        defer { commit() }
        if let share = record as? CKShare {
            updateSpace(from: share)
            return false
        }
        guard let space = spaceCreatingIfNeeded(for: record.recordID.zoneID),
            let cache = try? provider.cache(for: space)
        else { return false }

        switch record.recordType {
        case SharedRecordType.entry:
            return applyEntry(record, cache: cache)
        case SharedRecordType.revision:
            guard let revision = try? SharedRecordMapper.revision(from: record) else {
                return false
            }
            try? cache.importRevision(revision)
            var state =
                metadata.records[revision.id.uuidString]
                ?? RecordState(type: .revision(entryID: revision.entryID))
            state.zoneName = record.recordID.zoneID.zoneName
            state.systemFields = Self.encodeSystemFields(of: record)
            state.hasUnsentChanges = false
            metadata.records[revision.id.uuidString] = state
            return false
        default:
            return false
        }
    }

    public func resolveConflict(server record: CKRecord) -> Bool {
        applyFetched(record)
    }

    public func applyFetchedDeletion(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType) {
        defer { commit() }
        metadata.records[recordID.recordName] = nil
        guard recordType == SharedRecordType.entry,
            let space = space(for: recordID.zoneID),
            let id = UUID(uuidString: recordID.recordName)
        else { return }
        try? provider.cache(for: space).removeSynced(entryID: id)
    }

    public func didSave(_ record: CKRecord) {
        guard var state = metadata.records[record.recordID.recordName] else { return }
        state.systemFields = Self.encodeSystemFields(of: record)
        if case .entry = state.type,
            let payload = try? SharedRecordMapper.entryPayload(from: record)
        {
            state.base = payload.entry.draft
            // Only clear the flag if nothing was edited while this save was in flight.
            let current = space(for: record.recordID.zoneID)
                .flatMap { try? provider.cache(for: $0).entry(id: payload.entry.id) }
            state.hasUnsentChanges = current?.currentRevisionID != payload.entry.currentRevisionID
        } else {
            state.hasUnsentChanges = false
        }
        metadata.records[record.recordID.recordName] = state
        persist()
    }

    public func forgetServerRecord(_ recordID: CKRecord.ID) {
        metadata.records[recordID.recordName]?.systemFields = nil
        persist()
    }

    public func removeSpace(zoneID: CKRecordZone.ID) {
        guard let space = space(for: zoneID) else { return }
        try? provider.removeCache(for: space)
        metadata.spaces.removeAll { $0.space.id == space.id }
        metadata.records = metadata.records.filter { $0.value.zoneName != space.zoneName }
        commit()
    }

    public func resetAll() {
        for state in metadata.spaces {
            try? provider.removeCache(for: state.space)
        }
        metadata = Metadata()
        commit()
    }

    // MARK: Merging

    private func applyEntry(_ record: CKRecord, cache: any SharedEntryCache) -> Bool {
        guard let payload = try? SharedRecordMapper.entryPayload(from: record) else { return false }
        let remote = payload.entry
        var state = metadata.records[remote.id.uuidString] ?? RecordState(type: .entry)
        state.systemFields = Self.encodeSystemFields(of: record)
        state.kind = payload.kind
        state.zoneName = record.recordID.zoneID.zoneName
        defer { metadata.records[remote.id.uuidString] = state }

        guard state.hasUnsentChanges, let local = try? cache.entry(id: remote.id),
            local.currentRevisionID != remote.currentRevisionID
        else {
            try? cache.upsertSynced(remote)
            state.base = remote.draft
            state.hasUnsentChanges = false
            return false
        }

        // Both sides edited since the last agreed version. Both revisions are already in the
        // history (ours locally, theirs as a SharedRevision record), so the merge only has to
        // produce the new current text.
        let merged = SharedEntryMerge.merge(
            base: state.base,
            local: local.draft,
            localStamp: SharedEditStamp(
                updatedAt: local.updatedAt, deviceID: local.modifiedByDeviceID),
            remote: remote.draft,
            remoteStamp: SharedEditStamp(
                updatedAt: remote.updatedAt, deviceID: remote.modifiedByDeviceID)
        )
        state.base = remote.draft
        var draft = merged.draft
        draft.id = remote.id
        guard let saved = try? cache.save(draft, deviceID: deviceID, at: .now) else { return false }
        if let deletedAt = local.deletedAt ?? remote.deletedAt {
            var deleted = saved
            deleted.deletedAt = deletedAt
            try? cache.upsertSynced(deleted)
        }
        state.hasUnsentChanges = true
        metadata.records[saved.currentRevisionID.uuidString] = RecordState(
            type: .revision(entryID: saved.id), hasUnsentChanges: true,
            zoneName: record.recordID.zoneID.zoneName)
        onEnqueue?(
            [SharedRecordMapper.recordID(for: saved.currentRevisionID, in: record.recordID.zoneID)],
            [])
        return true
    }

    // MARK: Helpers

    private func space(for zoneID: CKRecordZone.ID) -> SharedSpaceRecord? {
        metadata.spaces.first { $0.space.zoneName == zoneID.zoneName }?.space
    }

    /// Another device of this user (or the owner) may add a space we have not seen yet;
    /// its name arrives with the zone's share record.
    private func spaceCreatingIfNeeded(for zoneID: CKRecordZone.ID) -> SharedSpaceRecord? {
        if let space = space(for: zoneID) { return space }
        guard let id = SharedSpaceRecord.id(fromZoneName: zoneID.zoneName) else { return nil }
        let isOwner = zoneID.ownerName == CKCurrentUserDefaultName
        let space = SharedSpaceRecord(
            id: id, scope: .notebook, name: "", role: isOwner ? .owner : .participant)
        metadata.spaces.append(SpaceState(space: space, zoneOwnerName: zoneID.ownerName))
        return space
    }

    private func updateSpace(from share: CKShare) {
        let zoneID = share.recordID.zoneID
        guard spaceCreatingIfNeeded(for: zoneID) != nil,
            let index = metadata.spaces.firstIndex(where: { $0.space.zoneName == zoneID.zoneName })
        else { return }
        if let title = share[CKShare.SystemFieldKey.title] as? String, !title.isEmpty {
            metadata.spaces[index].space.name = title
        }
        metadata.spaces[index].space.participantCount = share.participants.count
        metadata.spaces[index].space.ownerName = share.owner.userIdentity.nameComponents.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
        }
        metadata.spaces[index].space.updatedAt = .now
    }

    private func serverRecord(_ state: RecordState, type: CKRecord.RecordType, id: CKRecord.ID)
        -> CKRecord
    {
        if let data = state.systemFields, let record = Self.decodeSystemFields(data) {
            return record
        }
        return CKRecord(recordType: type, recordID: id)
    }

    private func commit() {
        spaces = metadata.spaces.map(\.space)
        persist()
        onChange?()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(metadata).write(to: metadataURL, options: [.atomic])
        } catch {
            assertionFailure("Shared sync metadata could not be saved: \(error)")
        }
    }

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Persisted state

    struct Metadata: Codable {
        var spaces: [SpaceState] = []
        var records: [String: RecordState] = [:]
        var privateState: CKSyncEngine.State.Serialization?
        var sharedState: CKSyncEngine.State.Serialization?
    }

    struct SpaceState: Codable {
        var space: SharedSpaceRecord
        /// `CKCurrentUserDefaultName` for spaces this user owns, the owner's record name otherwise.
        var zoneOwnerName: String
    }

    struct RecordState: Codable {
        enum RecordType: Codable, Equatable {
            case entry
            case revision(entryID: UUID)
        }

        var type: RecordType
        var hasUnsentChanges = false
        var zoneName: String?
        var systemFields: Data?
        /// The last version this device and the server agreed on, the base of a merge.
        var base: JournalEntryDraft?
        var kind: SharedKindSnapshot?
    }
}
