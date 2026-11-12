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
    /// Set when a kind deletion or reconcile rewrites entries underneath an
    /// open editor; the editor showing one of them reloads it from the store.
    @Published var editorReloadRequest: EditorReloadRequest?
    /// Which view the 기도노트 content column shows: the note list or one of the
    /// aggregated topic lists. Reset to `.notes` whenever the kind changes.
    @Published var prayerScope: PrayerScope = .notes
    @Published var ongoingPrayerItems: [PrayerTopicItem] = []
    @Published var answeredPrayerSections: [AnsweredPrayerMonthSection] = []
    /// User-saved section layouts (이름 붙인 템플릿) offered when a prayer note is empty.
    @Published var prayerTemplates: [PrayerNoteTemplate] = []
    @Published var newEntryNotebookName: String?
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
    @Published var attachmentRevision = 0
    @Published private(set) var isCloudImportInProgress = false
    @Published var kindCatalog: KindCatalog
    /// Kind IDs found on loaded entries that the catalog does not know yet
    /// (e.g. a kind created on another device whose catalog has not arrived).
    @Published var unknownKinds: [JournalKind] = []
    @Published var isPresentingKindManagement = false

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

    /// Text/tag/date filters only (unlike `hasActiveSearchCriteria`, which also
    /// counts the kind/notebook selection). While these are active the timeline
    /// shows search hits, so the prayer segments and aggregates stand down.
    var hasActiveSearchFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !searchTags.isEmpty
            || searchStartDate != nil
            || searchEndDate != nil
    }

    var isPrayerKindSelected: Bool { selectedKind?.builtIn == .prayer }

    let repository: any JournalRepository
    let importStore: any ImportAuditStore
    let searchIndex: JournalSearchIndex
    let paths: JournalPaths
    let deviceID: String
    #if PILGRIM_SWIFTDATA
    /// Shared notebooks, set for iCloud scopes only. Owned here so its sync engines stop
    /// when the journal store closes.
    var familySharing: FamilySharingController?
    #endif
    /// The shared notebook shown in the list instead of a kind or notebook.
    @Published var selectedSharedSpaceID: UUID?
    /// The shared notebook a new entry goes into, captured when the editor opened.
    var newEntrySharedSpaceID: UUID?
    /// For each open shared entry, the revision its editor started from, so a save
    /// merges with changes that arrived meanwhile instead of overwriting them.
    var sharedEditBases: [UUID: UUID] = [:]
    /// True while this device writes to a shared notebook, so the store's change
    /// callback is not mistaken for another member's edit.
    var isApplyingLocalSharedEdit = false
    let cloudAccountMonitor: CloudAccountMonitor?
    let kindCatalogStore: KindCatalogStore
    let prayerTemplateStore: PrayerTemplateStore
    /// Set by the first `refresh()`, which runs the one full reconcile pass
    /// that later refreshes skip.
    private var hasReconciledKinds = false
    /// True while `saveAndReturnRecord` runs. Every entry save comes from an
    /// editor, so a reconcile reached through that save's refresh must not
    /// flush the editor: it is the one saving, and it has not recorded the
    /// saved entry's ID yet.
    var isSavingEntry = false
    private let searchCoordinator: SearchIndexCoordinator
    let notebookDefaults: UserDefaults
    let notebookCloudStore: NSUbiquitousKeyValueStore?
    var deletedNotebookNames: [String]
    var dayOneTask: Task<Void, Never>?
    /// Constructed once rather than per-call — `AttachmentFileStore.init`
    /// touches the filesystem (`createDirectory`), and this is read from
    /// hot paths like `hasLocalBinary`/`attachmentData` that can run once
    /// per attachment row per render.
    lazy var attachmentFileStore: AttachmentFileStore? =
        try? AttachmentFileStore(root: paths.attachments)

    static let notebookDefaultsKey = "journal-notebooks"
    static let deletedNotebookDefaultsKey = "journal-deleted-notebooks"
    /// The notebook keys mirrored to the iCloud key-value store, which
    /// account deletion clears.
    static let cloudKeyValueKeys = [notebookDefaultsKey, deletedNotebookDefaultsKey]

    init(
        repository: any JournalRepository,
        importStore: any ImportAuditStore,
        searchIndex: JournalSearchIndex,
        paths: JournalPaths,
        cloudAccountMonitor: CloudAccountMonitor?,
        notebookDefaults: UserDefaults = .standard,
        notebookCloudStore: NSUbiquitousKeyValueStore? = nil
    ) {
        self.repository = repository
        self.importStore = importStore
        self.searchIndex = searchIndex
        self.paths = paths
        self.cloudAccountMonitor = cloudAccountMonitor
        self.notebookDefaults = notebookDefaults
        self.notebookCloudStore = notebookCloudStore
        kindCatalogStore = KindCatalogStore(
            defaults: notebookDefaults,
            cloudStore: notebookCloudStore
        )
        kindCatalog = kindCatalogStore.catalog
        prayerTemplateStore = PrayerTemplateStore(
            defaults: notebookDefaults,
            cloudStore: notebookCloudStore
        )
        prayerTemplates = prayerTemplateStore.catalog.activeTemplates
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
                message: event.errorDescription ?? String(localized: "CloudKit 동기화에 실패했습니다."),
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
        mergePrayerTemplatesFromCloud()
        let kindCatalogChanged = mergeKindCatalogFromCloud()
        if kindCatalogChanged || !hasReconciledKinds {
            hasReconciledKinds = true
            reconcileKinds()
        }
        if let selectedSharedSpaceID {
            refreshSharedSpaceEntries(selectedSharedSpaceID)
            return
        }
        do {
            let needsSearchIndex = hasActiveSearchFilters
            if !needsSearchIndex {
                if isPrayerKindSelected && prayerScope != .notes {
                    entries = try allPrayerEntries()
                } else {
                    entries = try repository.list(
                        kind: selectedKind,
                        includeDeleted: false,
                        limit: 500
                    )
                }
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
            refreshPrayerAggregates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markLocalMutation() {
        switch syncState {
        case .localOnly, .unavailable:
            break
        case .savedLocally, .pending, .synced, .failed:
            syncState = .pending
        }
    }

    private var searchTags: [String] {
        searchTagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Entries rewritten underneath any open editor. A fresh `id` makes every
/// request a change, even for the same entries.
struct EditorReloadRequest: Equatable {
    let id = UUID()
    let entryIDs: Set<UUID>
}
