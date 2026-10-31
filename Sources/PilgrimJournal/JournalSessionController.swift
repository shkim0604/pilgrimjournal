import Combine
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
    @Published private(set) var isReopeningForSync = false
    @Published var errorMessage: String?
    /// The Apple user the journal was last opened for. Kept after
    /// `deactivate`, so a retried account deletion still knows whose data
    /// to remove (the developer bypass has no signed-in identifier).
    private(set) var lastAppleUserIdentifier: String?

    private var rootURL: URL
    private let cloudKitContainerIdentifier: String?
    private let isVisualTesting: Bool
    private let storageLocationProvider: () async -> JournalStorageLocation
    private var registry: JournalAccountScopeRegistry
    /// Set while the storage folder could not be located. `activate` retries
    /// it, so the error screen's retry can recover from a transient failure.
    private var unresolvedRootProvider: (() throws -> URL)?

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

    /// Resolves the storage root now and, if that fails, again on every
    /// `activate` until it succeeds; until then `activate` reports the error
    /// on the session error screen instead of opening a store.
    convenience init(
        rootURLProvider: @escaping () throws -> URL,
        cloudKitContainerIdentifier: String?,
        isVisualTesting: Bool = false
    ) {
        do {
            self.init(
                rootURL: try rootURLProvider(),
                cloudKitContainerIdentifier: cloudKitContainerIdentifier,
                isVisualTesting: isVisualTesting
            )
        } catch {
            // Placeholder only: nothing reads it before the root resolves.
            self.init(
                rootURL: FileManager.default.temporaryDirectory,
                cloudKitContainerIdentifier: cloudKitContainerIdentifier,
                isVisualTesting: isVisualTesting
            )
            unresolvedRootProvider = rootURLProvider
        }
    }

    func activate(
        appleUserIdentifier: String,
        forceRefresh: Bool = false
    ) async {
        guard !isLoading else { return }
        lastAppleUserIdentifier = appleUserIdentifier
        if let provider = unresolvedRootProvider {
            do {
                let root = try provider()
                rootURL = root
                registry = JournalAccountScopeRegistry(root: root)
                unresolvedRootProvider = nil
            } catch {
                errorMessage = String(
                    localized: "기록 저장 위치를 준비하지 못했습니다. \(error.localizedDescription)")
                return
            }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let storageLocation =
                isVisualTesting
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
                    )
                {
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

    /// The storage this device would use now, read fresh rather than from
    /// `activeScope`: a pending local-to-iCloud migration keeps the local
    /// scope open even though the user's records also live in iCloud.
    func currentStorageLocation() async -> JournalStorageLocation {
        isVisualTesting ? .localOnly : await storageLocationProvider()
    }

    /// Closes the stores before account deletion removes their files. Views
    /// still holding the old model let go once SwiftUI re-renders, so give
    /// it a moment before the caller deletes anything.
    func closeForAccountDeletion() async {
        deactivate()
        errorMessage = nil
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Whether 지금 동기화 has anything to do: an open iCloud scope that is
    /// not waiting on a local-to-iCloud migration.
    var canReopenForSync: Bool {
        guard case .iCloud = activeScope?.storageLocation else { return false }
        return pendingMigration == nil && appModel != nil
    }

    /// Reopens the iCloud store so CloudKit mirroring sets up, fetches and
    /// uploads again, as it does at launch. SwiftData has no public "sync
    /// now"; loading the store is what schedules a fetch.
    ///
    /// The old model is let go first, because two containers mirroring the
    /// same store in one process fight over CloudKit's export and import
    /// work. If something still holds it after `releaseTimeout`, it is put
    /// back rather than opening a second copy of the store. Callers must not
    /// capture the current `AppModel` across this call.
    @discardableResult
    func reopenForManualSync(
        releaseTimeout: Duration = .seconds(2)
    ) async -> Bool {
        guard !isLoading, !isReopeningForSync, canReopenForSync,
            let scope = activeScope,
            let appleUserIdentifier = lastAppleUserIdentifier
        else { return false }
        isReopeningForSync = true
        defer { isReopeningForSync = false }

        let wasPresentingSettings = appModel?.isPresentingSettings ?? false
        weak var previousModel = appModel
        deactivate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: releaseTimeout)
        while previousModel != nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Something else (an account change) already opened a store.
        if appModel != nil { return true }
        if let stillHeld = previousModel {
            activeScope = scope
            appModel = stillHeld
            stillHeld.errorMessage = String(
                localized: "다른 작업이 기록을 사용하고 있어 동기화를 다시 시작하지 못했습니다. 잠시 후 다시 시도하세요.")
            return false
        }

        await activate(appleUserIdentifier: appleUserIdentifier, forceRefresh: true)
        guard let model = appModel else { return false }
        if wasPresentingSettings {
            model.showSettings()
        }
        await model.refreshCloudAccountState()
        return true
    }

    @discardableResult
    func confirmPendingMigration() -> JournalScopeMigrationResult? {
        guard let pendingMigration,
            activeScope == pendingMigration.source,
            let sourceModel = appModel
        else {
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
            paths = JournalPaths(
                root: rootURL.appending(
                    path: scope.relativeDirectory,
                    directoryHint: .isDirectory
                ))
            try paths.prepare()
        } else {
            paths = try registry.prepareScope(scope)
        }

        // Set only when this scope syncs through iCloud and a container exists.
        let syncedContainerIdentifier: String?
        if case .iCloud = scope.storageLocation {
            syncedContainerIdentifier = cloudKitContainerIdentifier
        } else {
            syncedContainerIdentifier = nil
        }

        let repository: any JournalRepository
        let importStore: any ImportAuditStore
        #if PILGRIM_SWIFTDATA
        let container = try JournalContainerFactory.make(
            inMemory: isVisualTesting,
            cloudKitContainerIdentifier: syncedContainerIdentifier,
            storageDirectory: isVisualTesting ? nil : paths.root
        )
        repository = SwiftDataJournalRepository(container: container)
        importStore = LocalImportStore(container: container)
        #else
        repository = try InMemoryJournalRepository(
            persistingTo: paths.root.appending(path: "journal-local.json")
        )
        importStore = InMemoryImportStore()
        #endif

        let defaults = UserDefaults(suiteName: scope.userDefaultsSuiteName) ?? .standard
        return try AppModel(
            repository: repository,
            importStore: importStore,
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "journal-search.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: syncedContainerIdentifier.map {
                CloudAccountMonitor(containerIdentifier: $0)
            },
            notebookDefaults: defaults,
            notebookCloudStore: syncedContainerIdentifier == nil ? nil : .default,
            featureAccess: PremiumCodeFeatureAccess()
        )
    }

    private func migrateLegacyDataIfNeeded(
        to destinationModel: AppModel,
        scope: JournalAccountScope
    ) throws {
        guard !isVisualTesting,
            try registry.shouldMigrateLegacyData(for: scope)
        else {
            return
        }
        let legacyDirectory = rootURL.deletingLastPathComponent()
        let legacyCanonicalURL = legacyDirectory.appending(path: "Canonical.store")
        let legacyJSONURL = rootURL.appending(path: "journal-local.json")
        guard
            FileManager.default.fileExists(atPath: legacyCanonicalURL.path)
                || FileManager.default.fileExists(atPath: legacyJSONURL.path)
        else {
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
            repository: InMemoryJournalRepository(persistingTo: legacyJSONURL),
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
        guard
            let source = sourceModel.repository
                as? any BackupRestoreRepository & AttachmentRepository,
            let destination = destinationModel.repository
                as? any BackupRestoreRepository & AttachmentRepository
        else {
            throw JournalAccountScopeError.invalidScopeManifest
        }
        let result = try JournalScopeMigrationService().migrate(
            from: source,
            to: destination
        )
        // Each scope keeps its own catalog; without this, custom kinds would
        // arrive as unknown IDs and deleted built-ins would come back.
        destinationModel.adoptKindCatalog(sourceModel.kindCatalog)
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
