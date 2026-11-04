import CloudKit
import Foundation
import JournalDomain

/// The local side of family sharing: per-space caches that hold shared entries and
/// revisions, and the CloudKit system fields of each record so saves keep their change tags.
@MainActor
public protocol SharedSyncStore: AnyObject {
    func stateSerialization(for scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization?
    func saveStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization, for scope: CKDatabase.Scope)
    /// The `pilgrim-share-*` zones this user owns. The private-database engine fetches only
    /// these, so it never downloads the journal's own Core Data zone.
    var ownedZoneIDs: [CKRecordZone.ID] { get }

    /// The record to upload for a pending save, built from the local copy on top of the
    /// last known server record, or nil when the local copy is gone.
    func recordToSave(_ recordID: CKRecord.ID) -> CKRecord?
    /// Another device's change arrived. Merge it into the local copy if that copy has
    /// unsent edits; returns true when the merged result still needs to be sent.
    func applyFetched(_ record: CKRecord) -> Bool
    func applyFetchedDeletion(_ recordID: CKRecord.ID, recordType: CKRecord.RecordType)
    /// A save went through; keep the server's system fields for the next save.
    func didSave(_ record: CKRecord)
    /// The server copy changed since our last fetch. Merge it in like a fetched change.
    func resolveConflict(server record: CKRecord) -> Bool
    /// The server has no copy (it was deleted, or the zone was reset): forget system fields.
    func forgetServerRecord(_ recordID: CKRecord.ID)

    /// The space's zone is gone: the owner stopped sharing, or this user left.
    func removeSpace(zoneID: CKRecordZone.ID)
    /// The iCloud account changed; drop every cached space and sync state.
    func resetAll()
}

/// Runs one `CKSyncEngine` per database: `.private` for the spaces this user owns (their
/// `pilgrim-share-*` zones) and `.shared` for spaces other family members shared with them.
/// The private journal itself is still mirrored by SwiftData and never goes through here.
@MainActor
public final class SharedSyncEngineHost {
    public let container: CKContainer
    private let store: SharedSyncStore
    private var engines: [CKDatabase.Scope: CKSyncEngine] = [:]
    private var delegates: [CKDatabase.Scope: EngineDelegate] = [:]

    public init(container: CKContainer, store: SharedSyncStore) {
        self.container = container
        self.store = store
    }

    public func start() {
        for scope in [CKDatabase.Scope.private, .shared] where engines[scope] == nil {
            let delegate = EngineDelegate(host: self, scope: scope)
            let configuration = CKSyncEngine.Configuration(
                database: scope == .private
                    ? container.privateCloudDatabase : container.sharedCloudDatabase,
                stateSerialization: store.stateSerialization(for: scope),
                delegate: delegate
            )
            delegates[scope] = delegate
            engines[scope] = CKSyncEngine(configuration)
        }
    }

    public func stop() {
        engines.removeAll()
        delegates.removeAll()
    }

    /// Queues local edits. Owned spaces live in the private database, received ones in the
    /// shared database; the zone's owner name tells them apart.
    public func enqueueSave(_ recordIDs: [CKRecord.ID]) {
        for (scope, ids) in Dictionary(grouping: recordIDs, by: Self.scope(of:)) {
            engines[scope]?.state.add(pendingRecordZoneChanges: ids.map { .saveRecord($0) })
        }
    }

    public func enqueueDelete(_ recordIDs: [CKRecord.ID]) {
        for (scope, ids) in Dictionary(grouping: recordIDs, by: Self.scope(of:)) {
            engines[scope]?.state.add(pendingRecordZoneChanges: ids.map { .deleteRecord($0) })
        }
    }

    /// Pulls now instead of waiting for a push: used on foregrounding and while a shared
    /// entry is open, since silent pushes can be late or coalesced.
    public func fetchChanges() async throws {
        for (scope, engine) in engines {
            try await engine.fetchChanges(fetchOptions(scope: scope))
        }
    }

    public func sendChanges() async throws {
        for engine in engines.values {
            try await engine.sendChanges()
        }
    }

    nonisolated static func scope(of recordID: CKRecord.ID) -> CKDatabase.Scope {
        recordID.zoneID.ownerName == CKCurrentUserDefaultName ? .private : .shared
    }

    // MARK: Events

    fileprivate func handle(
        _ event: CKSyncEngine.Event, scope: CKDatabase.Scope, engine: CKSyncEngine
    ) {
        switch event {
        case .stateUpdate(let update):
            store.saveStateSerialization(update.stateSerialization, for: scope)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn: break
            case .signOut, .switchAccounts: store.resetAll()
            @unknown default: store.resetAll()
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions {
                store.removeSpace(zoneID: deletion.zoneID)
            }

        case .fetchedRecordZoneChanges(let changes):
            var resend: [CKRecord.ID] = []
            for modification in changes.modifications where store.applyFetched(modification.record)
            {
                resend.append(modification.record.recordID)
            }
            for deletion in changes.deletions {
                store.applyFetchedDeletion(deletion.recordID, recordType: deletion.recordType)
            }
            engine.state.add(pendingRecordZoneChanges: resend.map { .saveRecord($0) })

        case .sentRecordZoneChanges(let sent):
            sent.savedRecords.forEach(store.didSave)
            handleFailedSaves(sent.failedRecordSaves, scope: scope, engine: engine)

        default:
            break
        }
    }

    private func handleFailedSaves(
        _ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
        scope: CKDatabase.Scope,
        engine: CKSyncEngine
    ) {
        var retry: [CKRecord.ID] = []
        var missingZones: Set<CKRecordZone.ID> = []
        for failure in failures {
            let recordID = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, store.resolveConflict(server: server) {
                    retry.append(recordID)
                }
            case .zoneNotFound where scope == .private:
                missingZones.insert(recordID.zoneID)
                retry.append(recordID)
            case .zoneNotFound, .userDeletedZone:
                store.removeSpace(zoneID: recordID.zoneID)
            case .unknownItem:
                store.forgetServerRecord(recordID)
                retry.append(recordID)
            default:
                // Network, throttling and quota errors are retried by the engine itself.
                break
            }
        }
        if !missingZones.isEmpty {
            engine.state.add(
                pendingDatabaseChanges: missingZones.map { .saveZone(CKRecordZone(zoneID: $0)) })
        }
        engine.state.add(pendingRecordZoneChanges: retry.map { .saveRecord($0) })
    }

    fileprivate func nextBatch(
        _ context: CKSyncEngine.SendChangesContext,
        engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = engine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.recordToSave(recordID, engine: engine)
        }
    }

    fileprivate func fetchOptions(scope: CKDatabase.Scope) -> CKSyncEngine.FetchChangesOptions {
        var options = CKSyncEngine.FetchChangesOptions()
        if scope == .private {
            options.scope = .zoneIDs(store.ownedZoneIDs)
        }
        return options
    }

    private func recordToSave(_ recordID: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        guard let record = store.recordToSave(recordID) else {
            engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
        return record
    }
}

/// `CKSyncEngine` wants a `Sendable` delegate it can call off the main actor; this forwards
/// each call to the host on the main actor, where the SwiftData caches live.
private final class EngineDelegate: CKSyncEngineDelegate, Sendable {
    private weak let host: SharedSyncEngineHost?
    private let scope: CKDatabase.Scope

    init(host: SharedSyncEngineHost, scope: CKDatabase.Scope) {
        self.host = host
        self.scope = scope
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await MainActor.run { host?.handle(event, scope: scope, engine: syncEngine) }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await host?.nextBatch(context, engine: syncEngine)
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        await host?.fetchOptions(scope: scope) ?? context.options
    }
}
