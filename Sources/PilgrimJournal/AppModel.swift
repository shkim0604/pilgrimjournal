import DayOneImport
import Foundation
import Combine
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI
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
    @Published var includeSourceSnapshotsInBackup = false
    @Published var isImportingBackup = false
    @Published var pendingRestoreData: Data?
    @Published var lastRestoreResult: RestoreResult?
    @Published var trashEntries: [JournalEntryRecord] = []
    @Published var isPresentingTrash = false
    @Published var lastSafetyBackupURL: URL?
    @Published var lastIntegrityReport: JournalIntegrityReport?
    @Published var lastRestoreFailureMessage: String?
    @Published var dataOperationDescription: String?
    @Published var lastRestoreConflicts: [RestoreConflictSummary] = []
    @Published private(set) var attachmentRevision = 0

    var selectedEntry: JournalEntryRecord? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
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
    private let cloudAccountMonitor: CloudAccountMonitor?
    private let searchCoordinator: SearchIndexCoordinator
    private let notebookDefaults: UserDefaults
    private let notebookCloudStore: NSUbiquitousKeyValueStore?
    private var deletedNotebookNames: [String]
    private var dayOneTask: Task<Void, Never>?

    private static let notebookDefaultsKey = "journal-notebooks"
    private static let deletedNotebookDefaultsKey = "journal-deleted-notebooks"

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
            syncState = .pending
            return
        }
        guard event.succeeded else {
            updateAttachmentTransferStates(
                matching: [.pending, .downloading],
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
            updateAttachmentTransferStates(matching: [.pending], to: .uploaded)
            syncState = .synced(completedAt)
        case .importing:
            reconcileDownloadedAttachments()
            syncState = .synced(completedAt)
            rebuildSearchIndex()
            refresh()
        }
    }

    #if PILGRIM_SWIFTDATA
    func handleJournalStoreChange(_ change: JournalStoreChange) {
        if change.requiresFullRefresh {
            rebuildSearchIndex()
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
        do {
            let needsSearchIndex = !searchText
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
                let hits = try searchIndex.search(JournalSearchQuery(
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
            if let selectedNotebookName {
                entries = entries.filter {
                    $0.notebookName?.caseInsensitiveCompare(selectedNotebookName) == .orderedSame
                }
            }
        } catch {
            errorMessage = error.localizedDescription
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
        guard let notebook = notebooks.first(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) else { return false }

        do {
            var cursor: JournalTimelineCursor?
            repeat {
                let page = try repository.page(
                    kind: nil,
                    includeDeleted: false,
                    after: cursor,
                    limit: 500
                )
                for entry in page.entries where entry.notebookName?
                    .caseInsensitiveCompare(notebook) == .orderedSame {
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
                == .orderedSame {
                selectedNotebookName = nil
            }
            if newEntryNotebookName?.caseInsensitiveCompare(notebook)
                == .orderedSame {
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
        newEntryNotebookName = selectedNotebookName
        editorSessionID = UUID()
        isPresentingEditor = true
    }

    func selectEntry(_ entryID: UUID?) {
        selectedEntryID = entryID
        guard entryID != nil else { return }
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
            return Array(Set(
                try repository.list(
                    kind: nil,
                    includeDeleted: false,
                    limit: 100_000
                ).flatMap(\.visibleTags)
            )).sorted()
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
               }) {
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
        let hasContent = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else { return }
        if let id = draft.id,
           let current = try? repository.entry(id: id),
           current.isDeleted {
            return
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
               movedEntryIDs.contains(selectedEntryID) {
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
              let attachmentRepository = repository as? any AttachmentRepository else {
            return []
        }
        do {
            return try attachmentRepository.allAttachments()
                .map(\.0)
                .filter { $0.entryID == entryID && $0.deletedAt == nil }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func hasLocalBinary(for attachmentID: UUID) -> Bool {
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            return false
        }
        return (try? attachmentRepository.allAttachments().first {
            $0.0.id == attachmentID
        }?.1) != nil
    }

    @discardableResult
    func addAttachment(from url: URL, to entryID: UUID) -> Bool {
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            errorMessage = "이 저장소에서는 첨부 파일을 사용할 수 없습니다."
            return false
        }
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let contentType = UTType(filenameExtension: url.pathExtension)
            let stored = try AttachmentFileStore(root: paths.attachments).store(
                data: data,
                entryID: entryID,
                originalName: url.lastPathComponent,
                mimeType: contentType?.preferredMIMEType ?? "application/octet-stream"
            )
            var record = stored.record
            record.state = cloudAccountMonitor == nil ? .local : .pending
            record.updatedAt = .now
            try attachmentRepository.saveAttachment(record, binary: data)
            attachmentRevision += 1
            markLocalMutation()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func requestAttachmentDownload(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let stored = try attachmentRepository.allAttachments().first(where: {
                $0.0.id == attachmentID
            }) else { return }
            if stored.1 != nil {
                var available = stored.0
                available.state = cloudAccountMonitor == nil ? .local : .uploaded
                available.updatedAt = .now
                try attachmentRepository.saveAttachment(available, binary: stored.1)
                attachmentRevision += 1
                return
            }
            var downloading = stored.0
            downloading.state = .downloading
            downloading.updatedAt = .now
            try attachmentRepository.saveAttachment(downloading, binary: nil)
            attachmentRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryAttachmentTransfer(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let stored = try attachmentRepository.allAttachments().first(where: {
                $0.0.id == attachmentID
            }) else { return }
            var retrying = stored.0
            retrying.state = stored.1 == nil ? .downloading : .pending
            retrying.updatedAt = .now
            try attachmentRepository.saveAttachment(retrying, binary: stored.1)
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
              let preview = importPreview else { return false }
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
        guard archiveURL.deletingLastPathComponent().standardizedFileURL
            == paths.importStaging.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: archiveURL)
    }

    func prepareBackup() async {
        isWorking = true
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
                includeSourceSnapshots: includeSourceSnapshotsInBackup
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
                    BackupAttachment(record: $0.0, binary: $0.1)
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
            dataOperationDescription = mode == .replace
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
            markLocalMutation()
            rebuildSearchIndex()
        } catch {
            lastRestoreFailureMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
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
                BackupAttachment(record: $0.0, binary: $0.1)
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
            sourceSnapshots: snapshots
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
            for stored in try attachmentRepository.allAttachments()
            where states.contains(stored.0.state) && stored.0.deletedAt == nil {
                var record = stored.0
                record.state = newState
                record.updatedAt = .now
                try attachmentRepository.saveAttachment(record, binary: stored.1)
                didUpdate = true
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
            for stored in try attachmentRepository.allAttachments()
            where stored.0.state == .downloading && stored.1 != nil {
                var record = stored.0
                record.state = .uploaded
                record.updatedAt = .now
                try attachmentRepository.saveAttachment(record, binary: stored.1)
                didUpdate = true
            }
            if didUpdate { attachmentRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshNotebookCatalog(from records: [JournalEntryRecord]) {
        let discovered = records.compactMap(\.notebookName)
        var merged = notebooks
        for name in discovered where !Self.containsNotebook(
            name,
            in: deletedNotebookNames
        ) && !merged.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
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
        guard merged != notebooks
                || previousDeletedNotebookNames != deletedNotebookNames else {
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
                  }) else { continue }
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
