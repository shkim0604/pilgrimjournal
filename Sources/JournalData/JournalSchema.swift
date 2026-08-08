#if PILGRIM_SWIFTDATA
import SwiftData

public enum PilgrimJournalSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static let models: [any PersistentModel.Type] = [
        JournalEntryEntity.self,
        EntryRevisionEntity.self,
        AttachmentEntity.self,
        ClassificationRuleEntity.self,
        RestoreEpochEntity.self,
        ImportJobEntity.self,
        ImportItemEntity.self,
        SourceSnapshotEntity.self,
    ]

    public static let canonicalModels: [any PersistentModel.Type] = [
        JournalEntryEntity.self,
        EntryRevisionEntity.self,
        AttachmentEntity.self,
        ClassificationRuleEntity.self,
        RestoreEpochEntity.self,
    ]

    public static let localModels: [any PersistentModel.Type] = [
        ImportJobEntity.self,
        ImportItemEntity.self,
        SourceSnapshotEntity.self,
    ]
}

public enum PilgrimJournalMigrationPlan: SchemaMigrationPlan {
    public static let schemas: [any VersionedSchema.Type] = [
        PilgrimJournalSchemaV1.self,
    ]

    public static let stages: [MigrationStage] = []
}
#endif
