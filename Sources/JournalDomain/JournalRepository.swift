import Foundation

public struct JournalTimelineCursor: Codable, Equatable, Sendable {
    public var occurredAt: Date
    public var entryID: UUID

    public init(occurredAt: Date, entryID: UUID) {
        self.occurredAt = occurredAt
        self.entryID = entryID
    }
}

public struct JournalTimelinePage: Equatable, Sendable {
    public var entries: [JournalEntryRecord]
    public var nextCursor: JournalTimelineCursor?

    public init(
        entries: [JournalEntryRecord],
        nextCursor: JournalTimelineCursor?
    ) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// The result of a `purgeEntries` call: what was actually removed, so callers
/// (AppModel) can clean up things the repository deliberately doesn't know
/// about — CAS attachment files on disk, QuickLook preview temp copies,
/// retained Day One source snapshots.
public struct JournalPurgeSummary: Equatable, Sendable {
    public var purgedEntryIDs: Set<UUID>
    public var removedRevisionCount: Int
    public var removedAttachmentIDs: Set<UUID>
    public var releasedChecksums: Set<String>
    public var purgedSourceUUIDs: Set<String>

    public init(
        purgedEntryIDs: Set<UUID> = [],
        removedRevisionCount: Int = 0,
        removedAttachmentIDs: Set<UUID> = [],
        releasedChecksums: Set<String> = [],
        purgedSourceUUIDs: Set<String> = []
    ) {
        self.purgedEntryIDs = purgedEntryIDs
        self.removedRevisionCount = removedRevisionCount
        self.removedAttachmentIDs = removedAttachmentIDs
        self.releasedChecksums = releasedChecksums
        self.purgedSourceUUIDs = purgedSourceUUIDs
    }

    public static let empty = JournalPurgeSummary()
}

@MainActor
public protocol JournalRepository: AnyObject {
    func list(kind: JournalKind?, includeDeleted: Bool, limit: Int) throws -> [JournalEntryRecord]
    func page(
        kind: JournalKind?,
        includeDeleted: Bool,
        after cursor: JournalTimelineCursor?,
        limit: Int
    ) throws -> JournalTimelinePage
    func entry(id: UUID) throws -> JournalEntryRecord?
    func entry(sourceUUID: String) throws -> JournalEntryRecord?
    func save(_ draft: JournalEntryDraft, deviceID: String, at date: Date) throws
        -> JournalEntryRecord
    func revisions(entryID: UUID) throws -> [EntryRevisionRecord]
    func restore(entryID: UUID, revisionID: UUID, deviceID: String, at date: Date) throws
        -> JournalEntryRecord
    func moveToTrash(entryID: UUID, deviceID: String, at date: Date) throws
    func restoreFromTrash(entryID: UUID, deviceID: String, at date: Date) throws
    /// Permanently removes the given entries — and their revisions and
    /// attachment rows — from storage. Every id MUST already be in the
    /// trash (`deletedAt != nil`); if any isn't, nothing is deleted and
    /// `JournalError.persistence` is thrown (validate-all-then-delete, so a
    /// caller bug can never turn into "some live entries got deleted too").
    /// IDs that no longer exist are skipped silently, so repeated calls are
    /// idempotent. Unlike `moveToTrash`, this writes no tombstone and no
    /// revision — there's nothing left to attribute to a device or time.
    func purgeEntries(ids: Set<UUID>) throws -> JournalPurgeSummary
    func classificationRules() throws -> [ClassificationRuleRecord]
    func saveClassificationRule(_ rule: ClassificationRuleRecord) throws
    func deleteClassificationRule(id: UUID) throws
}

/// An attachment row with its binary, which is `nil` while the binary has not
/// been downloaded to this device.
public struct StoredAttachment: Codable, Equatable, Sendable {
    public var record: AttachmentRecord
    public var binary: Data?

    public init(record: AttachmentRecord, binary: Data?) {
        self.record = record
        self.binary = binary
    }
}

@MainActor
public protocol AttachmentRepository: AnyObject {
    func allAttachments() throws -> [StoredAttachment]
    /// A single attachment by id, without scanning or materializing every
    /// other attachment's binary in storage — unlike `allAttachments()`,
    /// safe to call from a hot path (e.g. the live editor's inline image
    /// rendering) that only ever needs one specific attachment.
    func attachment(id: UUID) throws -> StoredAttachment?
    /// Just the checksum for one attachment, without touching `binary` —
    /// unlike `attachment(id:)`, which always faults the blob even when the
    /// caller only needs to know which CAS file to look for. Used to check
    /// CAS presence (`AttachmentFileStore.hasData(checksum:)`) without
    /// paying for a blob fault on every call.
    func attachmentChecksum(id: UUID) throws -> String?
    func saveAttachment(_ record: AttachmentRecord, binary: Data?) throws
    /// Checksums of every attachment row currently in storage, without
    /// touching the `binary` payload — used to recompute which CAS files on
    /// disk are still referenced after a purge, without faulting in
    /// potentially gigabytes of external-storage blobs.
    func attachmentChecksums() throws -> Set<String>
    /// Metadata for every attachment belonging to one entry, without
    /// touching `binary` — safe to call from a view body / hot path, unlike
    /// `allAttachments()` which faults every external-storage blob in the
    /// entire store just to filter by entryID.
    func attachments(forEntry entryID: UUID) throws -> [AttachmentRecord]
    /// Attachments currently in one of `states`, with binary — for callers
    /// that must inspect the binary to decide a state transition (e.g. "is
    /// the download actually done"). Scoped to just those states rather than
    /// `allAttachments()`'s full-table scan; in practice `states` is a
    /// small, transient subset (pending/uploading/downloading), so this
    /// still avoids faulting the vast majority of blobs in storage.
    func attachments(
        inStates states: Set<AttachmentTransferState>
    ) throws -> [StoredAttachment]
    /// Updates only the transfer state (and `updatedAt`) of one attachment
    /// row, leaving `binary` untouched. Returns whether a row with `id`
    /// existed. Use this instead of `saveAttachment(_:binary:)` for state
    /// transitions (upload/download progress) — round-tripping the binary
    /// through `saveAttachment` just to flip an enum rewrites the entire
    /// blob to disk for no reason.
    @discardableResult
    func updateAttachmentState(
        id: UUID, state: AttachmentTransferState, updatedAt: Date
    ) throws -> Bool
    /// Removes one attachment row (metadata + binary). Returns the removed
    /// row's checksum so the caller can release the underlying CAS file once
    /// it re-verifies no other row still references it — or `nil` if no row
    /// with `id` existed (idempotent under races).
    @discardableResult
    func deleteAttachment(id: UUID) throws -> String?
}

@MainActor
public protocol BackupRestoreRepository: JournalRepository {
    func performRestoreTransaction(_ operation: () throws -> Void) throws
    func importRevision(_ revision: EntryRevisionRecord) throws
    func saveRestoreEpoch(_ epoch: RestoreEpochRecord) throws
}

public struct RevisionResolver {
    public init() {}

    public func winner(
        _ lhs: EntryRevisionRecord,
        _ rhs: EntryRevisionRecord
    ) -> EntryRevisionRecord {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt ? lhs : rhs
        }
        if lhs.deviceID != rhs.deviceID {
            return lhs.deviceID.lexicographicallyPrecedes(rhs.deviceID) ? rhs : lhs
        }
        return lhs.id.uuidString.lexicographicallyPrecedes(rhs.id.uuidString) ? rhs : lhs
    }
}

public struct ClassificationCandidate: Sendable {
    public var tags: [String]
    public var templateUUID: String?
    public var templateTitle: String?

    public init(tags: [String], templateUUID: String?, templateTitle: String?) {
        self.tags = tags
        self.templateUUID = templateUUID
        self.templateTitle = templateTitle
    }
}

public struct ClassificationDecision: Equatable, Sendable {
    public var kind: JournalKind
    public var ruleID: UUID?
    public var isConflict: Bool

    public init(kind: JournalKind, ruleID: UUID?, isConflict: Bool) {
        self.kind = kind
        self.ruleID = ruleID
        self.isConflict = isConflict
    }
}

public struct ClassificationEngine {
    public init() {}

    public func classify(
        _ candidate: ClassificationCandidate,
        rules: [ClassificationRuleRecord]
    ) -> ClassificationDecision {
        let normalizedTags = Set(candidate.tags.map(normalize))
        let matches = rules.filter { rule in
            switch rule.source {
            case .tag:
                normalizedTags.contains(normalize(rule.value))
            case .templateUUID:
                candidate.templateUUID.map(normalize) == normalize(rule.value)
            case .templateTitle:
                candidate.templateTitle.map(normalize) == normalize(rule.value)
            }
        }

        guard let highestPriority = matches.map(\.priority).max() else {
            return ClassificationDecision(kind: .unclassified, ruleID: nil, isConflict: false)
        }
        let leaders = matches.filter { $0.priority == highestPriority }
        let targetKinds = Set(leaders.map(\.targetKind))
        guard targetKinds.count == 1, let winner = leaders.sorted(by: stableRuleOrder).first else {
            return ClassificationDecision(kind: .unclassified, ruleID: nil, isConflict: true)
        }
        return ClassificationDecision(kind: winner.targetKind, ruleID: winner.id, isConflict: false)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func stableRuleOrder(
        _ lhs: ClassificationRuleRecord,
        _ rhs: ClassificationRuleRecord
    ) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }
}

public struct ClassificationRuleResolver {
    public init() {}

    public func winner(
        _ lhs: ClassificationRuleRecord,
        _ rhs: ClassificationRuleRecord
    ) -> ClassificationRuleRecord {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        let lhsKey = stableContentKey(lhs)
        let rhsKey = stableContentKey(rhs)
        if lhsKey != rhsKey {
            return lhsKey.lexicographicallyPrecedes(rhsKey) ? rhs : lhs
        }
        return lhs.id.uuidString.lexicographicallyPrecedes(rhs.id.uuidString) ? rhs : lhs
    }

    private func stableContentKey(_ rule: ClassificationRuleRecord) -> String {
        [
            rule.source.rawValue,
            rule.value,
            rule.targetKind.rawValue,
            String(rule.priority),
        ].joined(separator: "\u{1F}")
    }
}
