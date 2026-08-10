import Foundation
import JournalDomain

public struct JournalScopeMigrationResult: Equatable, Sendable {
    public var migratedEntries: Int
    public var migratedRevisions: Int
    public var migratedRules: Int
    public var migratedAttachments: Int

    public init(
        migratedEntries: Int = 0,
        migratedRevisions: Int = 0,
        migratedRules: Int = 0,
        migratedAttachments: Int = 0
    ) {
        self.migratedEntries = migratedEntries
        self.migratedRevisions = migratedRevisions
        self.migratedRules = migratedRules
        self.migratedAttachments = migratedAttachments
    }
}

@MainActor
public struct JournalScopeMigrationService {
    public init() {}

    public func migrate(
        from source: any BackupRestoreRepository & AttachmentRepository,
        to destination: any BackupRestoreRepository & AttachmentRepository,
        deviceID: String = "account-scope-migration",
        at date: Date = .now
    ) throws -> JournalScopeMigrationResult {
        let sourceEntries = try source.list(
            kind: nil,
            includeDeleted: true,
            limit: 1_000_000
        )
        let sourceRevisions = try sourceEntries.flatMap {
            try source.revisions(entryID: $0.id)
        }
        let sourceRules = try source.classificationRules()
        let sourceAttachments = try source.allAttachments()
        var result = JournalScopeMigrationResult()

        try destination.performRestoreTransaction {
            for entry in sourceEntries {
                guard try destination.entry(id: entry.id) == nil else { continue }
                var draft = entry.draft
                draft.id = entry.id
                _ = try destination.save(
                    draft,
                    deviceID: deviceID,
                    at: max(entry.updatedAt, date)
                )
                if let deletedAt = entry.deletedAt {
                    try destination.moveToTrash(
                        entryID: entry.id,
                        deviceID: deviceID,
                        at: deletedAt
                    )
                }
                result.migratedEntries += 1
            }
            for revision in sourceRevisions {
                try destination.importRevision(revision)
                result.migratedRevisions += 1
            }
            for rule in sourceRules {
                try destination.saveClassificationRule(rule)
                result.migratedRules += 1
            }
            for attachment in sourceAttachments {
                try destination.saveAttachment(attachment.0, binary: attachment.1)
                result.migratedAttachments += 1
            }
        }
        return result
    }
}
