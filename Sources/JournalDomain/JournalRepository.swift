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
    func save(_ draft: JournalEntryDraft, deviceID: String, at date: Date) throws -> JournalEntryRecord
    func revisions(entryID: UUID) throws -> [EntryRevisionRecord]
    func restore(entryID: UUID, revisionID: UUID, deviceID: String, at date: Date) throws -> JournalEntryRecord
    func moveToTrash(entryID: UUID, deviceID: String, at date: Date) throws
    func restoreFromTrash(entryID: UUID, deviceID: String, at date: Date) throws
    func classificationRules() throws -> [ClassificationRuleRecord]
    func saveClassificationRule(_ rule: ClassificationRuleRecord) throws
    func deleteClassificationRule(id: UUID) throws
}

@MainActor
public protocol AttachmentRepository: AnyObject {
    func allAttachments() throws -> [(AttachmentRecord, Data?)]
    func saveAttachment(_ record: AttachmentRecord, binary: Data?) throws
}

@MainActor
public protocol BackupRestoreRepository: JournalRepository {
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
