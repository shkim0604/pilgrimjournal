#if PILGRIM_SWIFTDATA
import SwiftData

enum PilgrimJournalSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        JournalEntryEntity.self,
        EntryRevisionEntity.self,
        AttachmentEntity.self,
        ClassificationRuleEntity.self,
        RestoreEpochEntity.self,
        ImportJobEntity.self,
        ImportItemEntity.self,
        SourceSnapshotEntity.self,
    ]

    static let canonicalModels: [any PersistentModel.Type] = [
        JournalEntryEntity.self,
        EntryRevisionEntity.self,
        AttachmentEntity.self,
        ClassificationRuleEntity.self,
        RestoreEpochEntity.self,
    ]

    static let localModels: [any PersistentModel.Type] = [
        ImportJobEntity.self,
        ImportItemEntity.self,
        SourceSnapshotEntity.self,
    ]
}

enum PilgrimJournalMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        PilgrimJournalSchemaV1.self
    ]

    static let stages: [MigrationStage] = []
}
#endif
