import Foundation
import JournalDomain

public struct DayOneAttachmentReference: Codable, Equatable, Sendable {
    public var filename: String
    public var identifier: String?
    public var type: String?

    public init(filename: String, identifier: String?, type: String?) {
        self.filename = filename
        self.identifier = identifier
        self.type = type
    }
}

public struct DayOnePreviewItem: Identifiable, Sendable {
    public var id: UUID { stableEntryID }
    public var stableEntryID: UUID
    public var sourceUUID: String
    public var draft: JournalEntryDraft
    public var rawJSON: Data
    public var classification: ClassificationDecision
    public var attachments: [DayOneAttachmentReference]
    public var warnings: [String]

    public init(
        stableEntryID: UUID,
        sourceUUID: String,
        draft: JournalEntryDraft,
        rawJSON: Data,
        classification: ClassificationDecision,
        attachments: [DayOneAttachmentReference],
        warnings: [String]
    ) {
        self.stableEntryID = stableEntryID
        self.sourceUUID = sourceUUID
        self.draft = draft
        self.rawJSON = rawJSON
        self.classification = classification
        self.attachments = attachments
        self.warnings = warnings
    }
}

public struct DayOneImportPreview: Sendable {
    public var archiveURL: URL
    public var archiveFingerprint: String
    public var exportVersion: String
    public var jsonDisplayName: String
    public var items: [DayOnePreviewItem]
    public var duplicateSourceUUIDs: Set<String>
    public var optionalFieldCounts: [String: Int]
    public var missingAttachmentCount: Int
    public var warnings: [String]

    public init(
        archiveURL: URL,
        archiveFingerprint: String,
        exportVersion: String,
        jsonDisplayName: String,
        items: [DayOnePreviewItem],
        duplicateSourceUUIDs: Set<String>,
        optionalFieldCounts: [String: Int],
        missingAttachmentCount: Int,
        warnings: [String]
    ) {
        self.archiveURL = archiveURL
        self.archiveFingerprint = archiveFingerprint
        self.exportVersion = exportVersion
        self.jsonDisplayName = jsonDisplayName
        self.items = items
        self.duplicateSourceUUIDs = duplicateSourceUUIDs
        self.optionalFieldCounts = optionalFieldCounts
        self.missingAttachmentCount = missingAttachmentCount
        self.warnings = warnings
    }

    public var dateRange: ClosedRange<Date>? {
        guard let minimum = items.map(\.draft.occurredAt).min(),
            let maximum = items.map(\.draft.occurredAt).max()
        else {
            return nil
        }
        return minimum...maximum
    }

    public var unclassifiedCount: Int {
        items.filter { $0.classification.kind == .unclassified }.count
    }

    public func applying(
        itemOverrides: [String: JournalKind]
    ) -> DayOneImportPreview {
        var copy = self
        copy.items = items.map { item in
            guard let override = itemOverrides[item.sourceUUID] else { return item }
            var updated = item
            updated.draft.kind = override
            updated.classification = ClassificationDecision(
                kind: override,
                ruleID: nil,
                isConflict: false
            )
            return updated
        }
        return copy
    }

    public func assigningNotebook(
        _ name: String,
        to sourceUUIDs: Set<String>
    ) -> DayOneImportPreview {
        guard let normalized = NotebookTagCodec.normalizedName(name) else { return self }
        var copy = self
        copy.items = items.map { item in
            guard sourceUUIDs.contains(item.sourceUUID) else { return item }
            var updated = item
            updated.draft.notebookName = normalized
            return updated
        }
        return copy
    }
}

public enum DayOneImportOutcomeStatus: String, Sendable {
    case imported
    case skipped
    case failed
}

public struct DayOneImportOutcome: Identifiable, Sendable {
    public var id: String { sourceUUID }
    public var sourceUUID: String
    public var entryID: UUID?
    public var status: DayOneImportOutcomeStatus
    public var kind: JournalKind
    public var title: String
    public var message: String?
    public var warnings: [String]

    public init(
        sourceUUID: String,
        entryID: UUID?,
        status: DayOneImportOutcomeStatus,
        kind: JournalKind,
        title: String,
        message: String? = nil,
        warnings: [String] = []
    ) {
        self.sourceUUID = sourceUUID
        self.entryID = entryID
        self.status = status
        self.kind = kind
        self.title = title
        self.message = message
        self.warnings = warnings
    }
}

public struct DayOneImportResult: Sendable {
    public var succeeded: Int
    public var skipped: Int
    public var failed: Int
    public var warnings: [String]
    public var failures: [String]
    public var outcomes: [DayOneImportOutcome]

    public init(
        succeeded: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        warnings: [String] = [],
        failures: [String] = [],
        outcomes: [DayOneImportOutcome] = []
    ) {
        self.succeeded = succeeded
        self.skipped = skipped
        self.failed = failed
        self.warnings = warnings
        self.failures = failures
        self.outcomes = outcomes
    }
}

public enum DayOneExecutionEvent: Sendable {
    case imported(sourceUUID: String, entryID: UUID, rawJSON: Data)
    case skipped(sourceUUID: String, reason: String, rawJSON: Data)
    case failed(sourceUUID: String, reason: String, rawJSON: Data)
}
