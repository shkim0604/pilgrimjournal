#if PILGRIM_SWIFTDATA
import CoreData
import Foundation
import SwiftData

/// Pushes the canonical schema to the CloudKit **Development** environment.
///
/// CloudKit only auto-creates record types in Development, and only when a
/// record of that type is actually exported. Types the app rarely writes —
/// attachments, classification rules, restore epochs — therefore never appear,
/// so they cannot be promoted to Production and their exports are rejected
/// there. Reproducing every type by hand through the UI is slow and easy to
/// get wrong.
///
/// SwiftData has no schema-deployment API, but it is built on
/// `NSPersistentCloudKitContainer`, which does: `initializeCloudKitSchema()`
/// creates every record type and index the model implies. Bridging the
/// SwiftData models into a managed object model lets us call it against the
/// same container the app mirrors into.
///
/// This is a development tool. It refuses to run against a release build
/// because `initializeCloudKitSchema()` is documented as Development-only and
/// writes throwaway records.
public enum CloudKitSchemaInitializer {
    public enum Failure: LocalizedError {
        case managedObjectModelUnavailable
        case storeLoadFailed(any Error)

        public var errorDescription: String? {
            switch self {
            case .managedObjectModelUnavailable:
                String(localized: "SwiftData 모델을 Core Data 모델로 변환하지 못했습니다.", bundle: .module)
            case let .storeLoadFailed(error):
                String(
                    localized: "임시 저장소를 열지 못했습니다: \(error.localizedDescription)", bundle: .module)
            }
        }
    }

    /// Creates every canonical record type in the Development environment.
    ///
    /// Uses a throwaway store so it never touches the user's journal.
    public static func initializeDevelopmentSchema(
        cloudKitContainerIdentifier: String
    ) throws -> [String] {
        guard
            let model = NSManagedObjectModel.makeManagedObjectModel(
                for: PilgrimJournalSchemaV1.canonicalModels
            )
        else {
            throw Failure.managedObjectModelUnavailable
        }

        let container = NSPersistentCloudKitContainer(
            name: "Canonical",
            managedObjectModel: model
        )
        let storeDirectory = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-schema-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let description = NSPersistentStoreDescription(
            url: storeDirectory.appending(path: "SchemaSeed.store")
        )
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: cloudKitContainerIdentifier
        )
        // The schema push is synchronous, so the store has to be too.
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw Failure.storeLoadFailed(loadError) }

        try container.initializeCloudKitSchema(options: [])

        return model.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
    }
}
#endif
