#if PILGRIM_SWIFTDATA
import Foundation
import SwiftData

public enum JournalContainerFactory {
    public static let canonicalModels = PilgrimJournalSchemaV1.canonicalModels

    public static let localModels = PilgrimJournalSchemaV1.localModels

    /// The versioned schema's identifier as text, e.g. "1.0.0" (read by the admin console snapshot).
    public static let schemaVersionString = "\(PilgrimJournalSchemaV1.versionIdentifier)"

    @MainActor
    public static func make(
        inMemory: Bool = false,
        cloudKitContainerIdentifier: String? = nil,
        storageDirectory: URL? = nil
    ) throws -> ModelContainer {
        let version = PilgrimJournalSchemaV1.versionIdentifier
        let canonicalSchema = Schema(canonicalModels, version: version)
        let localSchema = Schema(localModels, version: version)
        let allSchema = Schema(versionedSchema: PilgrimJournalSchemaV1.self)

        let cloudDatabase: ModelConfiguration.CloudKitDatabase
        if let cloudKitContainerIdentifier {
            cloudDatabase = .private(cloudKitContainerIdentifier)
        } else {
            cloudDatabase = .none
        }

        let canonical: ModelConfiguration
        let local: ModelConfiguration
        if let storageDirectory, !inMemory {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            canonical = ModelConfiguration(
                "Canonical",
                schema: canonicalSchema,
                url: storageDirectory.appending(path: "Canonical.store"),
                cloudKitDatabase: cloudDatabase
            )
            local = ModelConfiguration(
                "LocalAuxiliary",
                schema: localSchema,
                url: storageDirectory.appending(path: "LocalAuxiliary.store"),
                cloudKitDatabase: .none
            )
        } else {
            canonical = ModelConfiguration(
                "Canonical",
                schema: canonicalSchema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudDatabase
            )
            local = ModelConfiguration(
                "LocalAuxiliary",
                schema: localSchema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: allSchema,
            migrationPlan: PilgrimJournalMigrationPlan.self,
            configurations: canonical,
            local
        )
    }
}
#endif
