import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

enum DayOneImportActivity: Equatable {
    case idle
    case analyzing
    case ready
    case importing(completed: Int, total: Int)
    case completed
    case failed
}

enum CloudSyncStoreOperation: Equatable, Sendable {
    case setup
    case importing
    case exporting
}

struct RestoreConflictSummary: Identifiable, Equatable {
    var id: UUID
    var currentTitle: String
    var backupTitle: String
}

/// A finished backup or restore, surfaced as a confirmation the user must see.
struct JournalOperationOutcome: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

struct CloudSyncStoreEvent: Equatable, Sendable {
    var operation: CloudSyncStoreOperation
    var completedAt: Date?
    var succeeded: Bool
    var errorDescription: String?
    var errorRetryable: Bool? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [JournalEntryRecord] = []
    @Published var selectedKind: JournalKind?
    @Published var notebooks: [String] = []
    @Published var selectedNotebookName: String?
    @Published var searchText = ""
    @Published var searchTagsText = ""
    @Published var searchStartDate: Date?
    @Published var searchEndDate: Date?
    @Published var syncState: SyncState
    @Published var errorMessage: String?
    @Published var selectedEntryID: UUID?
    @Published var editorSessionID = UUID()
    @Published private(set) var newEntryNotebookName: String?
    @Published var selectedEntryIDs = Set<UUID>()
    @Published var isBatchSelecting = false
    @Published var isPresentingBatchOrganizer = false
    @Published var isPresentingEditor = false
    @Published var isPresentingSettings = false
    @Published var editingEntry: JournalEntryRecord?
    @Published var isPresentingImporter = false
    @Published var importPreview: DayOneImportPreview?
    @Published var importResult: DayOneImportResult?
    @Published var importActivity = DayOneImportActivity.idle
    @Published var isWorking = false
    @Published var backupDocument: BackupDocument?
    @Published var isExportingBackup = false
    @Published var backupIncludesSourceSnapshots = false
    @Published var isImportingBackup = false
    @Published var pendingRestoreData: Data?
    @Published var lastRestoreResult: RestoreResult?
    @Published var lastBackupExportMessage: String?
    @Published var lastOperationOutcome: JournalOperationOutcome?
    @Published var trashEntries: [JournalEntryRecord] = []
    @Published var isPresentingTrash = false
    @Published var lastSafetyBackupURL: URL?
    @Published var lastIntegrityReport: JournalIntegrityReport?
    @Published var lastRestoreFailureMessage: String?
    @Published var dataOperationDescription: String?
    @Published var lastRestoreConflicts: [RestoreConflictSummary] = []
    @Published private(set) var attachmentRevision = 0
    @Published private(set) var isCloudImportInProgress = false
    @Published private(set) var kindCatalog: KindCatalog
    /// Kind IDs found on loaded entries that the catalog does not know yet
    /// (e.g. a kind created on another device whose catalog has not arrived).
    @Published private(set) var unknownKinds: [JournalKind] = []
    @Published var isPresentingKindManagement = false
    @Published var isPresentingPremiumNotice = false

    var selectedEntry: JournalEntryRecord? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    /// The kind a new entry starts as: the sidebar's kind when one that can be
    /// created by hand is selected, otherwise diary, otherwise the first kind
    /// that can be created (the catalog always keeps at least one).
    var defaultKindForNewEntry: JournalKind {
        let creatable = kindCatalog.creatableKinds
        if let selectedKind, creatable.contains(where: { $0.kind == selectedKind }) {
            return selectedKind
        }
        if creatable.contains(where: { $0.kind == .diary }) { return .diary }
        return creatable.first?.kind ?? .diary
    }

    var hasActiveSearchCriteria: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !searchTags.isEmpty
            || searchStartDate != nil
            || searchEndDate != nil
            || selectedKind != nil
            || selectedNotebookName != nil
    }

    let repository: any JournalRepository
    let importStore: any ImportAuditStore
    let searchIndex: JournalSearchIndex
    let paths: JournalPaths
    let deviceID: String
    let featureAccess: any FeatureAccess
    private let cloudAccountMonitor: CloudAccountMonitor?
    private let kindCatalogStore: KindCatalogStore
    /// Set by the first `refresh()`, which runs the one full reconcile pass
    /// that later refreshes skip.
    private var hasReconciledKinds = false
    private let searchCoordinator: SearchIndexCoordinator
    private let notebookDefaults: UserDefaults
    private let notebookCloudStore: NSUbiquitousKeyValueStore?
    private var deletedNotebookNames: [String]
    private var dayOneTask: Task<Void, Never>?
    /// Constructed once rather than per-call — `AttachmentFileStore.init`
    /// touches the filesystem (`createDirectory`), and this is read from
    /// hot paths like `hasLocalBinary`/`attachmentData` that can run once
    /// per attachment row per render.
    private lazy var attachmentFileStore: AttachmentFileStore? =
        try? AttachmentFileStore(root: paths.attachments)

    private static let notebookDefaultsKey = "journal-notebooks"
    private static let deletedNotebookDefaultsKey = "journal-deleted-notebooks"

    init(
        repository: any JournalRepository,
        importStore: any ImportAuditStore,
        searchIndex: JournalSearchIndex,
        paths: JournalPaths,
        cloudAccountMonitor: CloudAccountMonitor?,
        notebookDefaults: UserDefaults = .standard,
        notebookCloudStore: NSUbiquitousKeyValueStore? = nil,
        featureAccess: (any FeatureAccess)? = nil
    ) {
        self.repository = repository
        self.importStore = importStore
        self.searchIndex = searchIndex
        self.paths = paths
        self.cloudAccountMonitor = cloudAccountMonitor
        self.notebookDefaults = notebookDefaults
        self.notebookCloudStore = notebookCloudStore
        self.featureAccess = featureAccess ?? UnlockedFeatureAccess()
        kindCatalogStore = KindCatalogStore(
            defaults: notebookDefaults,
            cloudStore: notebookCloudStore
        )
        kindCatalog = kindCatalogStore.catalog
        searchCoordinator = SearchIndexCoordinator(index: searchIndex)
        notebookCloudStore?.synchronize()
        let initialDeletedNotebookNames = Self.mergedNotebookNames(
            notebookDefaults.stringArray(
                forKey: Self.deletedNotebookDefaultsKey
            ) ?? [],
            notebookCloudStore?.array(
                forKey: Self.deletedNotebookDefaultsKey
            ) as? [String] ?? []
        )
        deletedNotebookNames = initialDeletedNotebookNames
        notebooks = Self.mergedNotebookNames(
            notebookDefaults.stringArray(forKey: Self.notebookDefaultsKey) ?? [],
            notebookCloudStore?.array(forKey: Self.notebookDefaultsKey)
                as? [String] ?? []
        ).filter {
            !Self.containsNotebook($0, in: initialDeletedNotebookNames)
        }
        syncState = cloudAccountMonitor == nil ? .localOnly : .pending
        if let existing = UserDefaults.standard.string(forKey: "device-id") {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: "device-id")
            deviceID = generated
        }
    }

    func refreshCloudAccountState() async {
        guard let cloudAccountMonitor else {
            syncState = .localOnly
            return
        }
        applyCloudAccountProblem(await cloudAccountMonitor.currentProblem())
    }

    /// Only an account problem overrides the sync state. A usable account says
    /// nothing about whether a sync is in flight, so it leaves whatever the
    /// CloudKit events established. Reporting "pending" for a healthy account
    /// stranded the UI on 동기화 대기 until an event that never arrived.
    func applyCloudAccountProblem(_ problem: SyncState?) {
        guard let problem else { return }
        syncState = problem
    }

    func handleCloudSyncStoreEvent(_ event: CloudSyncStoreEvent) {
        guard cloudAccountMonitor != nil else { return }
        guard let completedAt = event.completedAt else {
            switch event.operation {
            case .exporting:
                updateAttachmentTransferStates(matching: [.pending], to: .uploading)
            case .importing:
                isCloudImportInProgress = true
            case .setup:
                break
            }
            syncState = .pending
            return
        }
        if event.operation == .importing {
            isCloudImportInProgress = false
        }
        guard event.succeeded else {
            updateAttachmentTransferStates(
                matching: [.pending, .downloading, .uploading],
                to: .failed
            )
            syncState = .failed(
                message: event.errorDescription ?? "CloudKit 동기화에 실패했습니다.",
                retryable: event.errorRetryable ?? true
            )
            return
        }

        switch event.operation {
        case .setup:
            syncState = .pending
        case .exporting:
            // .pending is matched alongside .uploading so an attachment whose
            // start-of-export event was missed (e.g. app backgrounded) still
            // reaches .uploaded from the completion event alone.
            updateAttachmentTransferStates(matching: [.pending, .uploading], to: .uploaded)
            syncState = .synced(completedAt)
        case .importing:
            reconcileDownloadedAttachments()
            syncState = .synced(completedAt)
            // Imported entries may still carry a kind this catalog deleted.
            reconcileKinds()
            rebuildSearchIndex()
            refresh()
        }
    }

    #if PILGRIM_SWIFTDATA
    func handleJournalStoreChange(_ change: JournalStoreChange) {
        if change.requiresFullRefresh {
            rebuildSearchIndex()
            // A canonical deletion (e.g. a permanent delete on another
            // window/device) can't be resolved back to an entry ID, so it
            // always takes this branch — make sure a currently-open trash
            // sheet reflects it too.
            if isPresentingTrash { refreshTrash() }
            return
        }

        do {
            var records = [UUID: JournalEntryRecord]()
            for id in change.entryIDs {
                if let record = try repository.entry(id: id) {
                    records[id] = record
                }
            }
            let changedIDs = change.entryIDs
            let historyToken = change.token
            let recordSnapshot = records
            Task { @MainActor [weak self, searchCoordinator] in
                await searchCoordinator.enqueue(changedIDs)
                do {
                    try await searchCoordinator.drain(
                        load: { id in recordSnapshot[id] },
                        newHistoryToken: historyToken
                    )
                    self?.refresh()
                    if self?.isPresentingTrash == true { self?.refreshTrash() }
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func refresh() {
        mergeNotebookCatalogFromCloud()
        let kindCatalogChanged = mergeKindCatalogFromCloud()
        if kindCatalogChanged || !hasReconciledKinds {
            hasReconciledKinds = true
            reconcileKinds()
        }
        do {
            let needsSearchIndex =
                !searchText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !searchTags.isEmpty
                || searchStartDate != nil
                || searchEndDate != nil
            if !needsSearchIndex {
                entries = try repository.list(
                    kind: selectedKind,
                    includeDeleted: false,
                    limit: 500
                )
            } else {
                let hits = try searchIndex.search(
                    JournalSearchQuery(
                        text: searchText,
                        kind: selectedKind,
                        tags: searchTags,
                        startDate: searchStartDate.map {
                            Calendar.current.startOfDay(for: $0)
                        },
                        endDate: searchEndDate.flatMap {
                            Calendar.current.date(
                                byAdding: DateComponents(day: 1, second: -1),
                                to: Calendar.current.startOfDay(for: $0)
                            )
                        }
                    ))
                entries = try hits.compactMap { try repository.entry(id: $0.id) }
            }
            refreshNotebookCatalog(from: entries)
            refreshUnknownKinds(from: entries)
            if let selectedNotebookName {
                entries = entries.filter {
                    $0.notebookName?.caseInsensitiveCompare(selectedNotebookName) == .orderedSame
                }
            }
            pruneSelectionToVisibleEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops selected ids that the current filter no longer shows.
    ///
    /// The list highlight only covers visible rows, so a stale id would arm the
    /// trash button for a note the user cannot see.
    private func pruneSelectionToVisibleEntries() {
        let visible = Set(entries.map(\.id))
        selectedEntryIDs.formIntersection(visible)
        if let selectedEntryID, !visible.contains(selectedEntryID) {
            self.selectedEntryID = nil
        }
    }

    func refreshNotebookCatalog() {
        mergeNotebookCatalogFromCloud()
        do {
            var cursor: JournalTimelineCursor?
            repeat {
                let page = try repository.page(
                    kind: nil,
                    includeDeleted: false,
                    after: cursor,
                    limit: 500
                )
                refreshNotebookCatalog(from: page.entries)
                cursor = page.nextCursor
            } while cursor != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSearchCriteria() {
        searchText = ""
        searchTagsText = ""
        searchStartDate = nil
        searchEndDate = nil
        selectedKind = nil
        selectedNotebookName = nil
        refresh()
    }

    func selectKind(_ kind: JournalKind?) {
        selectedKind = kind
        selectedNotebookName = nil
        newEntryNotebookName = nil
        editingEntry = nil
        isPresentingEditor = false
        endBatchSelection()
        refresh()
        selectedEntryID = entries.first?.id
    }

    func selectNotebook(_ name: String) {
        selectedKind = nil
        selectedNotebookName = name
        newEntryNotebookName = nil
        editingEntry = nil
        isPresentingEditor = false
        endBatchSelection()
        refresh()
        selectedEntryID = entries.first?.id
    }

    @discardableResult
    func createNotebook(named name: String) -> String? {
        guard let normalized = NotebookTagCodec.normalizedName(name) else {
            errorMessage = "노트북 이름을 입력해 주세요."
            return nil
        }
        if let existing = notebooks.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return existing
        }
        deletedNotebookNames.removeAll {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
        notebooks.append(normalized)
        notebooks.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        persistNotebookCatalog()
        return normalized
    }

    @discardableResult
    func deleteNotebook(named name: String) -> Bool {
        guard
            let notebook = notebooks.first(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            })
        else { return false }

        do {
            var cursor: JournalTimelineCursor?
            repeat {
                let page = try repository.page(
                    kind: nil,
                    includeDeleted: false,
                    after: cursor,
                    limit: 500
                )
                for entry in page.entries
                where entry.notebookName?
                    .caseInsensitiveCompare(notebook) == .orderedSame
                {
                    var draft = entry.draft
                    draft.notebookName = nil
                    let updated = try repository.save(
                        draft,
                        deviceID: deviceID,
                        at: .now
                    )
                    try searchIndex.upsert(updated)
                }
                cursor = page.nextCursor
            } while cursor != nil

            notebooks.removeAll {
                $0.caseInsensitiveCompare(notebook) == .orderedSame
            }
            if !Self.containsNotebook(notebook, in: deletedNotebookNames) {
                deletedNotebookNames.append(notebook)
            }
            if selectedNotebookName?.caseInsensitiveCompare(notebook)
                == .orderedSame
            {
                selectedNotebookName = nil
            }
            if newEntryNotebookName?.caseInsensitiveCompare(notebook)
                == .orderedSame
            {
                newEntryNotebookName = nil
            }
            persistNotebookCatalog()
            markLocalMutation()
            refresh()
            selectedEntryID = entries.first?.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func beginNewEntry() {
        editingEntry = nil
        selectedEntryID = nil
        selectedEntryIDs.removeAll()
        newEntryNotebookName = selectedNotebookName
        editorSessionID = UUID()
        isPresentingEditor = true
        // The macOS detail column checks settings first, so leaving this set
        // keeps settings on screen and the new note never appears.
        isPresentingSettings = false
    }

    func selectEntry(_ entryID: UUID?) {
        selectedEntryID = entryID
        if !isBatchSelecting {
            selectedEntryIDs = entryID.map { Set([$0]) } ?? []
        }
        guard entryID != nil else { return }
        editingEntry = nil
        isPresentingEditor = false
        isPresentingSettings = false
    }

    /// Applies a list selection that may hold more than one row.
    ///
    /// macOS `List` lets shift- and command-click extend the selection even
    /// when the binding carries a single optional id. The extra rows stay
    /// highlighted while the model only knows about one, so the window shows
    /// two green cards for one selected note. Holding the whole set keeps the
    /// highlight and the model in agreement, and gives the trash button
    /// something to act on without entering batch mode first.
    func selectEntries(_ entryIDs: Set<UUID>) {
        guard entryIDs.count != 1 else {
            selectEntry(entryIDs.first)
            return
        }
        selectedEntryIDs = entryIDs
        selectedEntryID = nil
        guard !entryIDs.isEmpty else { return }
        editingEntry = nil
        isPresentingEditor = false
        isPresentingSettings = false
    }

    func showSettings() {
        selectedEntryID = nil
        editingEntry = nil
        isPresentingEditor = false
        isPresentingSettings = true
        endBatchSelection()
    }

    func beginBatchSelection() {
        selectedEntryIDs = selectedEntryID.map { Set([$0]) } ?? []
        isBatchSelecting = true
    }

    func endBatchSelection() {
        selectedEntryIDs.removeAll()
        isBatchSelecting = false
    }

    func organizeSelectedEntries(
        targetKind: JournalKind?,
        addingTags: [String]
    ) -> Bool {
        do {
            let result = try JournalBatchOrganizer().apply(
                entryIDs: selectedEntryIDs,
                targetKind: targetKind,
                addingTags: addingTags,
                repository: repository,
                deviceID: deviceID,
                at: .now
            )
            for entry in result.updatedEntries {
                try searchIndex.upsert(entry)
            }
            markLocalMutation()
            isPresentingBatchOrganizer = false
            endBatchSelection()
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func availableTags() -> [String] {
        do {
            return Array(
                Set(
                    try repository.list(
                        kind: nil,
                        includeDeleted: false,
                        limit: 100_000
                    ).flatMap(\.visibleTags)
                )
            ).sorted()
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func classificationRules() -> [ClassificationRuleRecord] {
        do {
            return try repository.classificationRules()
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func saveClassificationRule(_ rule: ClassificationRuleRecord) -> Bool {
        do {
            try repository.saveClassificationRule(rule)
            markLocalMutation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteClassificationRule(id: UUID) {
        do {
            try repository.deleteClassificationRule(id: id)
            markLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameTag(_ oldName: String, to newName: String) -> Bool {
        updateTag(oldName, replacement: newName)
    }

    func removeTag(_ name: String) -> Bool {
        updateTag(name, replacement: nil)
    }

    func beginEditing(_ entry: JournalEntryRecord) {
        newEntryNotebookName = nil
        editingEntry = entry
        selectedEntryID = entry.id
        isPresentingEditor = true
    }

    @discardableResult
    func save(
        _ draft: JournalEntryDraft,
        closeEditor: Bool = true,
        selectSavedEntry: Bool = true
    ) -> Bool {
        saveAndReturnRecord(
            draft,
            closeEditor: closeEditor,
            selectSavedEntry: selectSavedEntry
        ) != nil
    }

    @discardableResult
    func saveAndReturnRecord(
        _ draft: JournalEntryDraft,
        closeEditor: Bool = true,
        selectSavedEntry: Bool = true
    ) -> JournalEntryRecord? {
        do {
            var outgoing = draft
            if let notebook = outgoing.notebookName,
                !notebooks.contains(where: {
                    $0.caseInsensitiveCompare(notebook) == .orderedSame
                })
            {
                outgoing.notebookName = nil
            }
            let record = try repository.save(
                outgoing,
                deviceID: deviceID,
                at: .now
            )
            try searchIndex.upsert(record)
            if selectSavedEntry {
                selectedEntryID = record.id
            }
            if closeEditor {
                editingEntry = nil
                isPresentingEditor = false
            }
            markLocalMutation()
            refresh()
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func autosaveOnEditorExit(_ draft: JournalEntryDraft) {
        let hasContent =
            !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent || draft.id != nil else { return }
        if let id = draft.id {
            // A trashed entry still exists (`entry(id:)` returns it, marked
            // deleted); a permanently deleted one doesn't exist at all
            // (`entry(id:)` returns nil). `try? repository.entry(id: id)`
            // flattens both "call failed" and "call succeeded with nil"
            // into the same `nil`, so `nil` here must also block the
            // autosave — otherwise a purge followed by closing an editor
            // that still had the old draft open would silently recreate
            // the entry.
            guard let current = try? repository.entry(id: id), !current.isDeleted else {
                return
            }
        }
        _ = save(draft, closeEditor: false, selectSavedEntry: false)
    }

    func isEntryDeleted(_ entryID: UUID?) -> Bool {
        guard let entryID else { return false }
        return (try? repository.entry(id: entryID))?.isDeleted == true
    }

    func moveToTrash(_ entry: JournalEntryRecord) {
        do {
            try repository.moveToTrash(entryID: entry.id, deviceID: deviceID, at: .now)
            if selectedEntryID == entry.id {
                selectedEntryID = nil
                editingEntry = nil
                isPresentingEditor = false
            }
            try searchIndex.remove(id: entry.id)
            markLocalMutation()
            refreshTrash()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func moveSelectedEntriesToTrash() -> Bool {
        let entryIDs = selectedEntryIDs
        guard !entryIDs.isEmpty else { return false }

        var movedEntryIDs = Set<UUID>()
        do {
            for entryID in entryIDs {
                try repository.moveToTrash(
                    entryID: entryID,
                    deviceID: deviceID,
                    at: .now
                )
                movedEntryIDs.insert(entryID)
                try searchIndex.remove(id: entryID)
            }
            if let selectedEntryID,
                movedEntryIDs.contains(selectedEntryID)
            {
                self.selectedEntryID = nil
                editingEntry = nil
                isPresentingEditor = false
            }
            markLocalMutation()
            endBatchSelection()
            refreshTrash()
            refresh()
            return true
        } catch {
            if !movedEntryIDs.isEmpty {
                selectedEntryIDs.subtract(movedEntryIDs)
                markLocalMutation()
                refreshTrash()
                refresh()
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func restoreFromTrash(_ entry: JournalEntryRecord) {
        do {
            try repository.restoreFromTrash(entryID: entry.id, deviceID: deviceID, at: .now)
            if let restored = try repository.entry(id: entry.id) {
                try searchIndex.upsert(restored)
            }
            markLocalMutation()
            refreshTrash()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores every trashed entry in `ids`. Stops at the first failure
    /// (matching `moveSelectedEntriesToTrash`'s error handling) but still
    /// refreshes if anything succeeded before that point.
    func restoreFromTrash(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var restoredEntryIDs = Set<UUID>()
        do {
            for id in ids {
                try repository.restoreFromTrash(entryID: id, deviceID: deviceID, at: .now)
                restoredEntryIDs.insert(id)
                if let restored = try repository.entry(id: id) {
                    try searchIndex.upsert(restored)
                }
            }
            markLocalMutation()
            refreshTrash()
            refresh()
        } catch {
            if !restoredEntryIDs.isEmpty {
                markLocalMutation()
                refreshTrash()
                refresh()
            }
            errorMessage = error.localizedDescription
        }
    }

    func refreshTrash() {
        do {
            trashEntries = try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100_000
            ).filter(\.isDeleted)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Permanently removes one trashed entry — its record, revisions, and
    /// attachments — from storage. Irreversible; the caller is expected to
    /// have already confirmed with the user.
    @discardableResult
    func permanentlyDelete(_ entry: JournalEntryRecord) -> Bool {
        applyPurge(ids: [entry.id], announceCount: false)
    }

    /// Permanently removes every entry in `ids` — same semantics as
    /// `permanentlyDelete(_:)`, batched for a multi-selection.
    @discardableResult
    func permanentlyDelete(ids: Set<UUID>) -> Bool {
        applyPurge(ids: ids, announceCount: true)
    }

    /// Permanently removes every entry currently in the trash. Re-lists the
    /// trash first so it acts on the current contents, not a possibly-stale
    /// `trashEntries` snapshot.
    @discardableResult
    func emptyTrash() -> Bool {
        refreshTrash()
        return applyPurge(ids: Set(trashEntries.map(\.id)), announceCount: true)
    }

    @discardableResult
    private func applyPurge(ids: Set<UUID>, announceCount: Bool) -> Bool {
        guard !ids.isEmpty else { return false }
        do {
            let summary = try repository.purgeEntries(ids: ids)
            guard !summary.purgedEntryIDs.isEmpty else { return false }

            for id in summary.purgedEntryIDs {
                try? searchIndex.remove(id: id)
            }

            // Unlike moveToTrash, check selectedEntryID and editingEntry
            // independently — a purge can be initiated from the trash sheet
            // while a *different* window still has the entry open in its
            // editor without it being the sidebar selection.
            if let selectedEntryID, summary.purgedEntryIDs.contains(selectedEntryID) {
                self.selectedEntryID = nil
            }
            if let editingEntry, summary.purgedEntryIDs.contains(editingEntry.id) {
                self.editingEntry = nil
                isPresentingEditor = false
            }
            selectedEntryIDs.subtract(summary.purgedEntryIDs)
            if selectedEntryIDs.isEmpty, isBatchSelecting {
                endBatchSelection()
            }

            attachmentRevision += 1
            releaseAttachmentFiles(summary.releasedChecksums)
            removePreviewTempFiles(for: summary.removedAttachmentIDs)
            try? importStore.removeSourceSnapshots(sourceUUIDs: summary.purgedSourceUUIDs)

            markLocalMutation()
            refreshTrash()
            refresh()

            if announceCount {
                lastOperationOutcome = JournalOperationOutcome(
                    title: "영구 삭제 완료",
                    message: "\(summary.purgedEntryIDs.count)개의 기록을 영구히 삭제했습니다."
                )
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Frees CAS attachment files no longer referenced by any remaining
    /// attachment row. Runs strictly after the repository commit (the
    /// caller just did that), so any failure here leaves an orphan file —
    /// wasted space, not lost data — rather than a file deleted ahead of a
    /// transaction that could still fail.
    private func releaseAttachmentFiles(_ checksums: Set<String>) {
        guard !checksums.isEmpty,
            let attachmentRepository = repository as? any AttachmentRepository
        else { return }
        do {
            let store = try AttachmentFileStore(root: paths.attachments)
            // Recomputed from the repository, over ALL remaining rows
            // (including still-trashed ones, which may yet be restored) —
            // never trust `checksums` alone, since checksums are shared
            // across entries via content-addressed dedup.
            let referenced = try attachmentRepository.attachmentChecksums()
            for checksum in checksums {
                try store.removeIfUnreferenced(checksum: checksum, referencedChecksums: referenced)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes the QuickLook/NSWorkspace preview temp copies
    /// `temporaryPreviewURL` writes — otherwise a "permanently deleted"
    /// attachment stays readable in plaintext under `tmp/` until the OS
    /// reaps it.
    private func removePreviewTempFiles(for attachmentIDs: Set<UUID>) {
        guard !attachmentIDs.isEmpty else { return }
        let base = FileManager.default.temporaryDirectory
            .appending(path: "AttachmentPreview", directoryHint: .isDirectory)
        for attachmentID in attachmentIDs {
            let directory = base.appending(
                path: attachmentID.uuidString,
                directoryHint: .isDirectory
            )
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func revisions(for entryID: UUID) -> [EntryRevisionRecord] {
        do {
            return try repository.revisions(entryID: entryID)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func restoreRevision(entryID: UUID, revisionID: UUID) {
        do {
            let restored = try repository.restore(
                entryID: entryID,
                revisionID: revisionID,
                deviceID: deviceID,
                at: .now
            )
            try searchIndex.upsert(restored)
            markLocalMutation()
            selectedEntryID = restored.id
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachments(for entryID: UUID?) -> [AttachmentRecord] {
        guard let entryID,
            let attachmentRepository = repository as? any AttachmentRepository
        else {
            return []
        }
        do {
            // Scoped to this entry and never touches `.binary` — unlike the
            // old `allAttachments()`-based version, which faulted every
            // attachment blob in the whole journal just to filter and
            // immediately discard them.
            return try attachmentRepository.attachments(forEntry: entryID)
                .filter { $0.deletedAt == nil }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Checks CAS file presence only — never faults the SwiftData blob.
    /// Fast path for attachments created on this device (their CAS file was
    /// written at upload time) and for anything already hydrated by a prior
    /// call. Only faults the DB blob (once, then self-heals — see
    /// `AttachmentFileStore.hydrate`) for attachments synced in from
    /// another device, whose CAS file was never written locally.
    func hasLocalBinary(for attachmentID: UUID) -> Bool {
        guard let attachmentRepository = repository as? any AttachmentRepository,
            let checksum = try? attachmentRepository.attachmentChecksum(id: attachmentID),
            let fileStore = attachmentFileStore
        else {
            return false
        }
        if fileStore.hasData(checksum: checksum) { return true }
        guard let stored = try? attachmentRepository.attachment(id: attachmentID),
            let binary = stored.binary
        else { return false }
        try? fileStore.hydrate(checksum: checksum, data: binary)
        return true
    }

    /// Same cheap-first, self-healing strategy as `hasLocalBinary`: try the
    /// mmap'd CAS file (no blob fault) before falling back to the SwiftData
    /// blob, hydrating the CAS on the way through so the next call is cheap.
    /// Backed by single-row queries throughout — safe for hot paths like the
    /// live editor's inline image rendering, which can be called often and
    /// must not scan the whole journal each time.
    func attachmentData(for attachmentID: UUID) -> Data? {
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            return nil
        }
        if let checksum = try? attachmentRepository.attachmentChecksum(id: attachmentID),
            let fileStore = attachmentFileStore,
            let cached = try? fileStore.data(checksum: checksum)
        {
            return cached
        }
        guard let stored = try? attachmentRepository.attachment(id: attachmentID)
        else { return nil }
        if let fileStore = attachmentFileStore, let binary = stored.binary {
            try? fileStore.hydrate(checksum: stored.record.checksum, data: binary)
        }
        return stored.binary
    }

    /// Writes the attachment's binary to a per-attachment temp directory so
    /// QuickLook (iOS) or the default external app (macOS) can open it by
    /// URL. The blob itself only lives in SwiftData's external storage
    /// attribute, not as a named file, so this is the only way to hand it to
    /// a URL-based viewer.
    func temporaryPreviewURL(for attachmentID: UUID) -> URL? {
        guard let attachmentRepository = repository as? any AttachmentRepository,
            let stored = try? attachmentRepository.attachment(id: attachmentID),
            let data = attachmentData(for: attachmentID)
        else { return nil }
        let record = stored.record
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AttachmentPreview", directoryHint: .isDirectory)
            .appending(path: attachmentID.uuidString, directoryHint: .isDirectory)
        let filename =
            record.originalName.isEmpty
            ? attachmentID.uuidString
            : record.originalName
        let url = directory.appending(path: filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Reading the file and hashing/writing it into the CAS store both scale
    /// with file size and used to run synchronously on the main actor,
    /// blocking editor typing while a large attachment imported. Both now
    /// happen off the main actor; only the final SwiftData save (which must
    /// stay on the main actor) runs here.
    @discardableResult
    func addAttachment(from url: URL, to entryID: UUID) async -> Bool {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            let contentType = UTType(filenameExtension: url.pathExtension)
            return await addAttachment(
                data: data,
                originalName: url.lastPathComponent,
                mimeType: contentType?.preferredMIMEType ?? "application/octet-stream",
                to: entryID
            ) != nil
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// See `addAttachment(from:to:)` — the CAS hash+write is offloaded for
    /// the same reason.
    @discardableResult
    func addAttachment(
        data: Data,
        originalName: String,
        mimeType: String,
        to entryID: UUID
    ) async -> UUID? {
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            errorMessage = "이 저장소에서는 첨부 파일을 사용할 수 없습니다."
            return nil
        }
        let attachmentsRoot = paths.attachments
        do {
            let stored = try await Task.detached(priority: .userInitiated) {
                try AttachmentFileStore(root: attachmentsRoot).store(
                    data: data,
                    entryID: entryID,
                    originalName: originalName,
                    mimeType: mimeType
                )
            }.value
            var record = stored.record
            record.state = cloudAccountMonitor == nil ? .local : .pending
            record.updatedAt = .now
            try attachmentRepository.saveAttachment(record, binary: data)
            attachmentRevision += 1
            markLocalMutation()
            return record.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Removes one attachment from its entry. Irreversible; the caller is
    /// expected to have already confirmed with the user. Frees the CAS file
    /// only if no other row (including other entries, via checksum dedupe)
    /// still references it.
    func deleteAttachment(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let checksum = try attachmentRepository.deleteAttachment(id: attachmentID)
            else { return }
            attachmentRevision += 1
            markLocalMutation()
            releaseAttachmentFiles([checksum])
            removePreviewTempFiles(for: [attachmentID])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestAttachmentDownload(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            // Single-row fetch — needed to know whether the binary is
            // already present (decides which state to transition to) — but
            // the actual write goes through `updateAttachmentState`, which
            // never rewrites that binary back to disk.
            guard let stored = try attachmentRepository.attachment(id: attachmentID)
            else { return }
            let newState: AttachmentTransferState =
                stored.binary != nil
                ? (cloudAccountMonitor == nil ? .local : .uploaded)
                : .downloading
            try attachmentRepository.updateAttachmentState(
                id: attachmentID, state: newState, updatedAt: .now
            )
            attachmentRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryAttachmentTransfer(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let stored = try attachmentRepository.attachment(id: attachmentID)
            else { return }
            let newState: AttachmentTransferState = stored.binary == nil ? .downloading : .pending
            try attachmentRepository.updateAttachmentState(
                id: attachmentID, state: newState, updatedAt: .now
            )
            attachmentRevision += 1
            markLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rebuildSearchIndex() {
        do {
            let all = try repository.list(kind: nil, includeDeleted: false, limit: 100_000)
            try searchIndex.rebuild(from: all)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func analyzeDayOne(url: URL) {
        dayOneTask?.cancel()
        do {
            try paths.prepare()
            let stagedURL = paths.importStaging.appending(
                path: "\(UUID().uuidString)-\(url.lastPathComponent)"
            )
            try FileManager.default.copyItem(at: url, to: stagedURL)
            // includeDeleted: true is intentional and must stay — a
            // trashed-but-not-purged entry still exists and must keep
            // blocking re-import of the same sourceUUID. Permanently
            // deleting it (via TrashView) removes the row entirely, so it
            // naturally drops out of `existing` and re-import is allowed
            // again; that's `purgeEntries`' job, not this scan's.
            let existing = try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100_000
            )
            let sourceUUIDs = Set(existing.compactMap(\.sourceUUID))
            let rules = try repository.classificationRules()
            importPreview = nil
            importResult = nil
            importActivity = .analyzing
            isWorking = true
            dayOneTask = Task { @MainActor [weak self] in
                do {
                    let preview = try await Task.detached(priority: .userInitiated) {
                        try DayOneArchiveAnalyzer().analyze(
                            archiveURL: stagedURL,
                            rules: rules,
                            knownSourceUUIDs: sourceUUIDs
                        )
                    }.value
                    try Task.checkCancellation()
                    self?.importPreview = preview
                    self?.importActivity = .ready
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: stagedURL)
                    self?.importActivity = .idle
                } catch {
                    try? FileManager.default.removeItem(at: stagedURL)
                    self?.errorMessage = error.localizedDescription
                    self?.importActivity = .failed
                }
                self?.isWorking = false
            }
        } catch {
            errorMessage = error.localizedDescription
            importActivity = .failed
            isWorking = false
        }
    }

    func setDayOneImportKind(_ kind: JournalKind, for sourceUUID: String) {
        guard let preview = importPreview else { return }
        importPreview = preview.applying(itemOverrides: [sourceUUID: kind])
    }

    func assignDayOneImportNotebook(
        named name: String,
        to sourceUUIDs: Set<String>
    ) -> Bool {
        guard !sourceUUIDs.isEmpty else {
            errorMessage = "노트북에 넣을 기록을 선택해 주세요."
            return false
        }
        guard let notebook = createNotebook(named: name),
            let preview = importPreview
        else { return false }
        importPreview = preview.assigningNotebook(notebook, to: sourceUUIDs)
        return true
    }

    func executeDayOneImport() {
        guard let preview = importPreview else { return }
        dayOneTask?.cancel()
        isWorking = true
        importActivity = .importing(completed: 0, total: preview.items.count)
        dayOneTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { cleanupStagedArchive(preview.archiveURL) }
            do {
                let jobID = try importStore.begin(
                    fingerprint: preview.archiveFingerprint,
                    displayName: preview.archiveURL.lastPathComponent,
                    totalCount: preview.items.count
                )
                let result = await DayOneImportExecutor().execute(
                    preview: preview,
                    repository: repository,
                    deviceID: deviceID
                ) { event in
                    do {
                        switch event {
                        case let .imported(sourceUUID, entryID, rawJSON):
                            try self.importStore.record(
                                jobID: jobID,
                                item: ImportAuditItem(
                                    sourceUUID: sourceUUID,
                                    entryID: entryID,
                                    status: .imported
                                ),
                                rawJSON: rawJSON
                            )
                        case let .skipped(sourceUUID, reason, rawJSON):
                            try self.importStore.record(
                                jobID: jobID,
                                item: ImportAuditItem(
                                    sourceUUID: sourceUUID,
                                    entryID: nil,
                                    status: .skipped,
                                    message: reason
                                ),
                                rawJSON: rawJSON
                            )
                        case let .failed(sourceUUID, reason, rawJSON):
                            try self.importStore.record(
                                jobID: jobID,
                                item: ImportAuditItem(
                                    sourceUUID: sourceUUID,
                                    entryID: nil,
                                    status: .failed,
                                    message: reason
                                ),
                                rawJSON: rawJSON
                            )
                        }
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                } onProgress: { completed, total in
                    self.importActivity = .importing(
                        completed: completed,
                        total: total
                    )
                }
                try importStore.finish(
                    jobID: jobID,
                    status: Task.isCancelled ? .cancelled : .completed,
                    succeeded: result.succeeded,
                    skipped: result.skipped,
                    failed: result.failed
                )
                importResult = result
                importActivity = .completed
                markLocalMutation()
                rebuildSearchIndex()
            } catch {
                errorMessage = error.localizedDescription
                importActivity = .failed
            }
            isWorking = false
        }
    }

    func cancelDayOneImport() {
        dayOneTask?.cancel()
    }

    func resetDayOneImport() {
        dayOneTask?.cancel()
        if let archiveURL = importPreview?.archiveURL {
            cleanupStagedArchive(archiveURL)
        }
        importPreview = nil
        importResult = nil
        importActivity = .idle
        isWorking = false
    }

    private func cleanupStagedArchive(_ archiveURL: URL) {
        guard
            archiveURL.deletingLastPathComponent().standardizedFileURL
                == paths.importStaging.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: archiveURL)
    }

    func prepareBackup() async {
        isWorking = true
        lastBackupExportMessage = nil
        dataOperationDescription = "백업 데이터 준비 중"
        await Task.yield()
        defer {
            isWorking = false
            dataOperationDescription = nil
        }
        do {
            let temporary = paths.backupStaging
                .appending(path: "\(UUID().uuidString).journalbackup")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writeCurrentBackup(
                to: temporary,
                includeSourceSnapshots: backupIncludesSourceSnapshots
            )
            backupDocument = BackupDocument(data: try Data(contentsOf: temporary))
            isExportingBackup = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runIntegrityCheck() {
        isWorking = true
        defer { isWorking = false }
        do {
            try searchIndex.integrityCheck()
            let allEntries = try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100_000
            )
            let revisions = try allEntries.flatMap {
                try repository.revisions(entryID: $0.id)
            }
            let attachments: [BackupAttachment]
            if let attachmentRepository = repository as? any AttachmentRepository {
                attachments = try attachmentRepository.allAttachments().map {
                    BackupAttachment(record: $0.record, binary: $0.binary)
                }
            } else {
                attachments = []
            }
            lastIntegrityReport = JournalIntegrityChecker().inspect(
                entries: allEntries,
                revisions: revisions,
                attachments: attachments,
                indexedEntryIDs: try searchIndex.indexedEntryIDs()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreBackup(data: Data, mode: RestoreMode) async {
        isWorking = true
        dataOperationDescription = "백업 검증 중"
        await Task.yield()
        defer {
            isWorking = false
            dataOperationDescription = nil
        }
        do {
            guard let restorable = repository as? any BackupRestoreRepository else {
                throw JournalError.persistence("현재 저장 adapter는 복원을 지원하지 않습니다.")
            }
            let temporary = paths.backupStaging
                .appending(path: "\(UUID().uuidString).journalbackup")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.atomic])
            let service = JournalBackupService()
            let contents = try service.readAndValidate(from: temporary)
            let current = try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100_000
            )
            if mode == .replace {
                dataOperationDescription = "현재 상태 안전 백업 중"
                await Task.yield()
                let safetyURL = paths.backupStaging.appending(
                    path: "SafetyBackup-\(Int(Date.now.timeIntervalSince1970)).journalbackup"
                )
                try writeCurrentBackup(
                    to: safetyURL,
                    includeSourceSnapshots: true
                )
                lastSafetyBackupURL = safetyURL
            }
            let plan = service.plan(
                contents: contents,
                currentEntries: current,
                mode: mode
            )
            lastRestoreConflicts = plan.conflicts.map { conflict in
                RestoreConflictSummary(
                    id: conflict.current.id,
                    currentTitle: conflict.current.title,
                    backupTitle: conflict.backup.title
                )
            }
            dataOperationDescription =
                mode == .replace
                ? "교체 복원 적용 중"
                : "병합 복원 적용 중"
            await Task.yield()
            lastRestoreResult = try JournalRestoreExecutor().execute(
                contents: contents,
                plan: plan,
                repository: restorable,
                deviceID: deviceID,
                at: .now
            )
            lastRestoreFailureMessage = nil
            pendingRestoreData = nil
            reportOutcome(
                title: mode == .replace ? "교체 복원 완료" : "병합 복원 완료",
                message: restoreSummary(lastRestoreResult)
            )
            markLocalMutation()
            // Restored entries may carry kinds the catalog has since deleted,
            // so this reconciles even when the backup has no catalog.
            if let backupCatalog = contents.kindCatalog {
                adoptKindCatalog(backupCatalog)
            } else {
                reconcileKinds()
            }
            rebuildSearchIndex()
            // Without this the list keeps showing the pre-restore state, which
            // reads as "nothing happened".
            refreshNotebookCatalog()
            refreshTrash()
            refresh()
        } catch {
            lastRestoreFailureMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    /// Records the result of a backup or restore for the confirmation alert.
    ///
    /// The settings form already carries the detail, but a caption inside a
    /// long scrolling form is easy to miss and disappears entirely when the
    /// form is not on screen. Both operations end with the user unsure whether
    /// anything happened, so the outcome is raised where it cannot be missed.
    func reportOutcome(title: String, message: String) {
        lastOperationOutcome = JournalOperationOutcome(
            title: title,
            message: message
        )
    }

    private func restoreSummary(_ result: RestoreResult?) -> String {
        guard let result else { return "복원이 끝났습니다." }
        return "\(result.restored)개 반영 · \(result.tombstoned)개 휴지통 · "
            + "충돌 \(result.conflicts)개"
    }

    func retryPendingRestore(mode: RestoreMode) async {
        guard let pendingRestoreData else { return }
        await restoreBackup(data: pendingRestoreData, mode: mode)
    }

    func restoreSafetyBackup() async {
        guard let lastSafetyBackupURL else { return }
        do {
            let data = try Data(contentsOf: lastSafetyBackupURL)
            pendingRestoreData = data
            await restoreBackup(data: data, mode: .replace)
        } catch {
            lastRestoreFailureMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    private func writeCurrentBackup(
        to url: URL,
        includeSourceSnapshots: Bool = false
    ) throws {
        let allEntries = try repository.list(
            kind: nil,
            includeDeleted: true,
            limit: 100_000
        )
        let revisions = try allEntries.flatMap {
            try repository.revisions(entryID: $0.id)
        }
        let attachments: [BackupAttachment]
        if let attachmentRepository = repository as? any AttachmentRepository {
            attachments = try attachmentRepository.allAttachments().map {
                BackupAttachment(record: $0.record, binary: $0.binary)
            }
        } else {
            attachments = []
        }
        let snapshots: [BackupSourceSnapshot]
        if includeSourceSnapshots {
            snapshots = try importStore.sourceSnapshots().map {
                BackupSourceSnapshot(sourceUUID: $0.key, rawJSON: $0.value)
            }
        } else {
            snapshots = []
        }
        try JournalBackupService().create(
            at: url,
            entries: allEntries,
            revisions: revisions,
            rules: try repository.classificationRules(),
            attachments: attachments,
            sourceSnapshots: snapshots,
            kindCatalog: kindCatalog
        )
    }

    private func markLocalMutation() {
        switch syncState {
        case .localOnly, .unavailable:
            break
        case .savedLocally, .pending, .synced, .failed:
            syncState = .pending
        }
    }

    private func updateAttachmentTransferStates(
        matching states: Set<AttachmentTransferState>,
        to newState: AttachmentTransferState
    ) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            var didUpdate = false
            // Scoped to just the matching states — a small, transient
            // subset — and never rewrites `binary` (unlike the old
            // saveAttachment(record, binary:) round-trip, which faulted
            // every matching row's blob just to flip an enum, and could
            // re-upload the same CKAsset on every sync event).
            for stored in try attachmentRepository.attachments(inStates: states)
            where stored.record.deletedAt == nil {
                if try attachmentRepository.updateAttachmentState(
                    id: stored.record.id, state: newState, updatedAt: .now
                ) {
                    didUpdate = true
                }
            }
            if didUpdate { attachmentRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reconcileDownloadedAttachments() {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            var didUpdate = false
            for stored in try attachmentRepository.attachments(inStates: [.downloading])
            where stored.binary != nil {
                if try attachmentRepository.updateAttachmentState(
                    id: stored.record.id, state: .uploaded, updatedAt: .now
                ) {
                    didUpdate = true
                }
            }
            if didUpdate { attachmentRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshNotebookCatalog(from records: [JournalEntryRecord]) {
        let discovered = records.compactMap(\.notebookName)
        var merged = notebooks
        for name in discovered
        where !Self.containsNotebook(
            name,
            in: deletedNotebookNames
        )
            && !merged.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            })
        {
            merged.append(name)
        }
        merged.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        guard merged != notebooks else { return }
        notebooks = merged
        persistNotebookCatalog()
    }

    private func persistNotebookCatalog() {
        notebookDefaults.set(notebooks, forKey: Self.notebookDefaultsKey)
        notebookDefaults.set(
            deletedNotebookNames,
            forKey: Self.deletedNotebookDefaultsKey
        )
        notebookCloudStore?.set(notebooks, forKey: Self.notebookDefaultsKey)
        notebookCloudStore?.set(
            deletedNotebookNames,
            forKey: Self.deletedNotebookDefaultsKey
        )
        notebookCloudStore?.synchronize()
    }

    private func mergeNotebookCatalogFromCloud() {
        guard let notebookCloudStore else { return }
        notebookCloudStore.synchronize()
        let previousDeletedNotebookNames = deletedNotebookNames
        deletedNotebookNames = Self.mergedNotebookNames(
            deletedNotebookNames,
            notebookCloudStore.array(forKey: Self.deletedNotebookDefaultsKey)
                as? [String] ?? []
        )
        let merged = Self.mergedNotebookNames(
            notebooks,
            notebookCloudStore.array(forKey: Self.notebookDefaultsKey)
                as? [String] ?? []
        ).filter { !Self.containsNotebook($0, in: deletedNotebookNames) }
        guard
            merged != notebooks
                || previousDeletedNotebookNames != deletedNotebookNames
        else {
            return
        }
        notebooks = merged
        persistNotebookCatalog()
    }

    private static func mergedNotebookNames(
        _ collections: [String]...
    ) -> [String] {
        var result: [String] = []
        for name in collections.joined() {
            guard let normalized = NotebookTagCodec.normalizedName(name),
                !result.contains(where: {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                })
            else { continue }
            result.append(normalized)
        }
        return result.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private static func containsNotebook(
        _ name: String,
        in names: [String]
    ) -> Bool {
        names.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func updateTag(
        _ oldName: String,
        replacement: String?
    ) -> Bool {
        do {
            let records: [JournalEntryRecord]
            if let replacement {
                records = try JournalTagManager().rename(
                    tag: oldName,
                    to: replacement,
                    repository: repository,
                    deviceID: deviceID
                )
            } else {
                records = try JournalTagManager().remove(
                    tag: oldName,
                    repository: repository,
                    deviceID: deviceID
                )
            }
            for record in records {
                try searchIndex.upsert(record)
            }
            markLocalMutation()
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var searchTags: [String] {
        searchTagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Journal kinds

extension AppModel {
    /// Active kinds in sidebar order, with kinds the catalog does not know
    /// listed just before 미분류.
    var sidebarKinds: [KindDefinition] {
        let active = kindCatalog.activeKinds
        return active.filter { !$0.kind.isUnclassified }
            + unknownKinds.map(KindCatalog.unknownDefinition(for:))
            + active.filter(\.kind.isUnclassified)
    }

    func kindDefinition(for kind: JournalKind) -> KindDefinition {
        kindCatalog.definition(for: kind)
    }

    func openKindManagement() {
        if featureAccess.canManageKinds {
            isPresentingKindManagement = true
        } else {
            isPresentingPremiumNotice = true
        }
    }

    /// Entries of `kind` outside the trash — the ones a deletion would move.
    func entryCount(for kind: JournalKind) throws -> Int {
        var count = 0
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: kind, includeDeleted: false, after: cursor, limit: 500)
            count += page.entries.count
            cursor = page.nextCursor
        } while cursor != nil
        return count
    }

    func createKind(
        name: String, colorToken: KindColorToken, iconToken: String
    ) throws -> JournalKind {
        try editKindCatalog { catalog, now in
            try catalog.create(
                name: name, colorToken: colorToken, iconToken: iconToken,
                deviceID: deviceID, at: now
            ).kind
        }
    }

    func updateKind(
        _ kind: JournalKind, name: String, colorToken: KindColorToken, iconToken: String
    ) throws {
        try editKindCatalog { catalog, now in
            try catalog.update(
                kind, name: name, colorToken: colorToken, iconToken: iconToken,
                deviceID: deviceID, at: now)
        }
    }

    func reorderKinds(_ ordered: [JournalKind]) throws {
        try editKindCatalog { catalog, now in
            try catalog.reorder(ordered, deviceID: deviceID, at: now)
        }
    }

    /// Marks `kind` deleted, then moves its entries and classification rules
    /// to `target`. The catalog is saved first, so if moving fails part-way
    /// the next reconcile pass moves whatever is left.
    func deleteKind(_ kind: JournalKind, moveTo target: JournalKind) throws {
        try editKindCatalog { catalog, now in
            try catalog.delete(kind, moveTarget: target, deviceID: deviceID, at: now)
        }
        defer {
            if selectedKind == kind {
                selectKind(nil)
            } else {
                refresh()
            }
        }
        let now = Date.now
        let service = KindDeletionService()
        let moved = try service.moveEntries(
            from: kind, to: target, repository: repository, deviceID: deviceID, at: now)
        for record in moved {
            try searchIndex.upsert(record)
        }
        _ = try service.retargetRules(from: kind, to: target, repository: repository, at: now)
    }

    func restoreKind(_ kind: JournalKind) throws {
        try editKindCatalog { catalog, now in
            try catalog.restore(kind, deviceID: deviceID, at: now)
        }
    }

    /// Merges a catalog from elsewhere (a restored backup, the local scope
    /// moving to iCloud) into this one, then moves entries and rules of kinds
    /// it deletes.
    func adoptKindCatalog(_ other: KindCatalog) {
        _ = mergeKindCatalogFromCloud()
        kindCatalogStore.save(kindCatalogStore.catalog.merged(with: other))
        applyStoredKindCatalog()
        deselectInactiveKind()
        reconcileKinds()
    }

    /// Applies `edit` to the latest catalog (merged from iCloud first, so a
    /// save never overwrites another device's edits this one has not seen)
    /// and saves it.
    private func editKindCatalog<Result>(
        _ edit: (inout KindCatalog, Date) throws -> Result
    ) throws -> Result {
        let cloudChanged = mergeKindCatalogFromCloud()
        if cloudChanged { reconcileKinds() }
        defer { if cloudChanged { refresh() } }
        var catalog = kindCatalogStore.catalog
        let result = try edit(&catalog, .now)
        kindCatalogStore.save(catalog)
        applyStoredKindCatalog()
        markLocalMutation()
        return result
    }

    /// Merges the iCloud catalog. Returns true when the local catalog changed;
    /// a selected kind that is no longer active is then deselected.
    private func mergeKindCatalogFromCloud() -> Bool {
        guard kindCatalogStore.mergeFromCloud() else { return false }
        applyStoredKindCatalog()
        deselectInactiveKind()
        return true
    }

    /// Clears a selected kind that the catalog has deleted meanwhile, without
    /// a nested refresh (callers refresh afterwards).
    private func deselectInactiveKind() {
        if let selectedKind, kindCatalog.isKnown(selectedKind),
            !kindCatalog.definition(for: selectedKind).isActive
        {
            self.selectedKind = nil
        }
    }

    /// Takes the store's (normalised) catalog and drops unknown IDs it now knows.
    private func applyStoredKindCatalog() {
        kindCatalog = kindCatalogStore.catalog
        unknownKinds.removeAll { kindCatalog.isKnown($0) }
    }

    /// Moves entries and rules whose kind the catalog marks deleted. Runs only
    /// at the trigger points (first refresh, catalog change from iCloud,
    /// CloudKit import, backup restore) — not on every refresh.
    private func reconcileKinds() {
        do {
            let moved = try KindReconciler().reconcile(
                catalog: kindCatalog, repository: repository, deviceID: deviceID, at: .now)
            for record in moved {
                try searchIndex.upsert(record)
            }
            if !moved.isEmpty { markLocalMutation() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Accumulates unknown kind IDs across refreshes so an unknown kind keeps
    /// its sidebar row while another kind is selected.
    private func refreshUnknownKinds(from records: [JournalEntryRecord]) {
        var merged = unknownKinds
        for kind in records.map(\.kind)
        where !kindCatalog.isKnown(kind) && !merged.contains(kind) {
            merged.append(kind)
        }
        merged.removeAll { kindCatalog.isKnown($0) }
        if merged != unknownKinds { unknownKinds = merged }
    }
}
