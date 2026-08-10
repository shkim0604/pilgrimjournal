import Combine
import DayOneImport
import Foundation
import JournalData
import JournalDomain
import JournalSearch
#if PILGRIM_SWIFTDATA
import SwiftData
#endif

struct PendingJournalScopeMigration: Equatable {
    var source: JournalAccountScope
    var destination: JournalAccountScope
    var entryCount: Int
}

@MainActor
final class JournalSessionController: ObservableObject {
    @Published private(set) var appModel: AppModel?
    @Published private(set) var activeScope: JournalAccountScope?
    @Published private(set) var pendingMigration: PendingJournalScopeMigration?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let rootURL: URL
    private let cloudKitContainerIdentifier: String?
    private let isVisualTesting: Bool
    private let storageLocationProvider: () async -> JournalStorageLocation
    private let registry: JournalAccountScopeRegistry

    init(
        rootURL: URL,
        cloudKitContainerIdentifier: String?,
        isVisualTesting: Bool = false,
        storageLocationProvider: (() async -> JournalStorageLocation)? = nil
    ) {
        self.rootURL = rootURL
        self.cloudKitContainerIdentifier = cloudKitContainerIdentifier
        self.isVisualTesting = isVisualTesting
        registry = JournalAccountScopeRegistry(root: rootURL)
        if let storageLocationProvider {
            self.storageLocationProvider = storageLocationProvider
        } else if let cloudKitContainerIdentifier {
            let monitor = CloudAccountMonitor(
                containerIdentifier: cloudKitContainerIdentifier
            )
            self.storageLocationProvider = {
                await monitor.currentStorageLocation()
            }
        } else {
            self.storageLocationProvider = { .localOnly }
        }
    }

    func activate(
        appleUserIdentifier: String,
        forceRefresh: Bool = false
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let storageLocation = isVisualTesting
                ? JournalStorageLocation.localOnly
                : await storageLocationProvider()
            let desiredScope = JournalAccountScope(
                appleUserIdentifier: appleUserIdentifier,
                storageLocation: storageLocation
            )
            if !forceRefresh, activeScope == desiredScope, appModel != nil {
                return
            }

            var desiredModel = try makeAppModel(for: desiredScope)
            try migrateLegacyDataIfNeeded(
                to: desiredModel,
                scope: desiredScope
            )

            if case .iCloud = storageLocation {
                let localScope = JournalAccountScope(
                    appleUserHash: desiredScope.appleUserHash,
                    storageLocation: .localOnly
                )
                if registry.hasPreparedScope(localScope),
                   !registry.hasCompletedMigration(
                       from: localScope,
                       to: desiredScope
                   ) {
                    let localModel = try makeAppModel(for: localScope)
                    let localCount = try localModel.repository.list(
                        kind: nil,
                        includeDeleted: true,
                        limit: 1_000_000
                    ).count
                    if localCount > 0 {
                        desiredModel = localModel
                        activeScope = localScope
                        appModel = localModel
                        pendingMigration = PendingJournalScopeMigration(
                            source: localScope,
                            destination: desiredScope,
                            entryCount: localCount
                        )
                        prepare(model: localModel)
                        errorMessage = nil
                        return
                    }
                }
            }

            activeScope = desiredScope
            appModel = desiredModel
            pendingMigration = nil
            prepare(model: desiredModel)
            errorMessage = nil
        } catch {
            appModel = nil
            activeScope = nil
            pendingMigration = nil
            errorMessage = error.localizedDescription
        }
    }

    func deactivate() {
        appModel = nil
        activeScope = nil
        pendingMigration = nil
        isLoading = false
    }

    @discardableResult
    func confirmPendingMigration() -> JournalScopeMigrationResult? {
        guard let pendingMigration,
              activeScope == pendingMigration.source,
              let sourceModel = appModel else {
            return nil
        }
        do {
            let destinationModel = try makeAppModel(
                for: pendingMigration.destination
            )
            let result = try migrate(
                from: sourceModel,
                to: destinationModel
            )
            try registry.markMigrationCompleted(
                from: pendingMigration.source,
                to: pendingMigration.destination
            )
            activeScope = pendingMigration.destination
            appModel = destinationModel
            self.pendingMigration = nil
            prepare(model: destinationModel)
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func keepLocalOnly() {
        pendingMigration = nil
    }

    private func makeAppModel(
        for scope: JournalAccountScope
    ) throws -> AppModel {
        let paths: JournalPaths
        if isVisualTesting {
            paths = JournalPaths(root: rootURL.appending(
                path: scope.relativeDirectory,
                directoryHint: .isDirectory
            ))
            try paths.prepare()
        } else {
            paths = try registry.prepareScope(scope)
        }

        let repository: any JournalRepository
        let importStore: any ImportAuditStore
        #if PILGRIM_SWIFTDATA
        let usesCloud: Bool
        if case .iCloud = scope.storageLocation {
            usesCloud = cloudKitContainerIdentifier != nil
        } else {
            usesCloud = false
        }
        let container = try JournalContainerFactory.make(
            inMemory: isVisualTesting,
            cloudKitContainerIdentifier: usesCloud
                ? cloudKitContainerIdentifier
                : nil,
            storageDirectory: isVisualTesting ? nil : paths.root
        )
        repository = SwiftDataJournalRepository(container: container)
        importStore = LocalImportStore(container: container)
        #else
        repository = try InMemoryJournalRepository(
            storageURL: paths.root.appending(path: "journal-local.json")
        )
        importStore = InMemoryImportStore()
        #endif

        let defaultsName = "PilgrimJournal.\(scope.appleUserHash).\(scope.storageLocation.directoryName)"
        let defaults = UserDefaults(suiteName: defaultsName) ?? .standard
        let usesICloud: Bool
        if case .iCloud = scope.storageLocation {
            usesICloud = cloudKitContainerIdentifier != nil
        } else {
            usesICloud = false
        }
        return try AppModel(
            repository: repository,
            importStore: importStore,
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "journal-search.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: usesICloud
                ? CloudAccountMonitor(
                    containerIdentifier: cloudKitContainerIdentifier!
                )
                : nil,
            notebookDefaults: defaults,
            notebookCloudStore: usesICloud ? .default : nil
        )
    }

    private func migrateLegacyDataIfNeeded(
        to destinationModel: AppModel,
        scope: JournalAccountScope
    ) throws {
        guard !isVisualTesting,
              try registry.shouldMigrateLegacyData(for: scope) else {
            return
        }
        let legacyDirectory = rootURL.deletingLastPathComponent()
        let legacyCanonicalURL = legacyDirectory.appending(path: "Canonical.store")
        let legacyJSONURL = rootURL.appending(path: "journal-local.json")
        guard FileManager.default.fileExists(atPath: legacyCanonicalURL.path)
                || FileManager.default.fileExists(atPath: legacyJSONURL.path) else {
            try registry.claimLegacyData(for: scope)
            return
        }

        #if PILGRIM_SWIFTDATA
        let legacyContainer = try JournalContainerFactory.make(
            cloudKitContainerIdentifier: nil,
            storageDirectory: legacyDirectory
        )
        let legacyModel = try AppModel(
            repository: SwiftDataJournalRepository(container: legacyContainer),
            importStore: LocalImportStore(container: legacyContainer),
            searchIndex: JournalSearchIndex(
                url: FileManager.default.temporaryDirectory.appending(
                    path: "legacy-search-\(UUID().uuidString).sqlite"
                )
            ),
            paths: JournalPaths(root: rootURL),
            cloudAccountMonitor: nil
        )
        #else
        let legacyModel = try AppModel(
            repository: InMemoryJournalRepository(storageURL: legacyJSONURL),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: FileManager.default.temporaryDirectory.appending(
                    path: "legacy-search-\(UUID().uuidString).sqlite"
                )
            ),
            paths: JournalPaths(root: rootURL),
            cloudAccountMonitor: nil
        )
        #endif
        _ = try migrate(from: legacyModel, to: destinationModel)
        try registry.claimLegacyData(for: scope)
    }

    private func migrate(
        from sourceModel: AppModel,
        to destinationModel: AppModel
    ) throws -> JournalScopeMigrationResult {
        guard let source = sourceModel.repository
                as? any BackupRestoreRepository & AttachmentRepository,
              let destination = destinationModel.repository
                as? any BackupRestoreRepository & AttachmentRepository else {
            throw JournalAccountScopeError.invalidScopeManifest
        }
        let result = try JournalScopeMigrationService().migrate(
            from: source,
            to: destination
        )
        let snapshots = try sourceModel.importStore.sourceSnapshots()
        if !snapshots.isEmpty {
            let jobID = try destinationModel.importStore.begin(
                fingerprint: "account-scope-migration",
                displayName: "기존 로컬 데이터",
                totalCount: snapshots.count
            )
            for (sourceUUID, rawJSON) in snapshots {
                try destinationModel.importStore.record(
                    jobID: jobID,
                    item: ImportAuditItem(
                        sourceUUID: sourceUUID,
                        entryID: try destination.entry(sourceUUID: sourceUUID)?.id,
                        status: .imported,
                        message: "계정별 저장소로 이전됨"
                    ),
                    rawJSON: rawJSON
                )
            }
            try destinationModel.importStore.finish(
                jobID: jobID,
                status: .completed,
                succeeded: snapshots.count,
                skipped: 0,
                failed: 0
            )
        }
        return result
    }

    private func prepare(model: AppModel) {
        model.refreshNotebookCatalog()
        model.rebuildSearchIndex()
        model.refreshTrash()
        model.refresh()
    }
}
