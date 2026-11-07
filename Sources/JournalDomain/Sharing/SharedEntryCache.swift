import Foundation

/// Local storage for one shared space. It is an ordinary journal repository, so the
/// existing list, editor and history code can read and edit shared entries, plus two writes
/// that copy another family member's change in as-is.
@MainActor
public protocol SharedEntryCache: BackupRestoreRepository {
    /// Writes an entry exactly as another device saved it, keeping its revision ID, edit
    /// time and deletion state, without recording a new revision on this device.
    func upsertSynced(_ entry: JournalEntryRecord) throws
    /// Removes an entry and its revisions after its server record was deleted.
    func removeSynced(entryID: UUID) throws
}

/// Opens and removes the local cache of each shared space.
@MainActor
public protocol SharedEntryCacheProvider: AnyObject {
    func cache(for space: SharedSpaceRecord) throws -> any SharedEntryCache
    func removeCache(for space: SharedSpaceRecord) throws
}
