import DayOneImport
import Foundation
import Combine
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI

enum DayOneImportActivity: Equatable {
    case idle
    case analyzing
    case ready
    case importing(completed: Int, total: Int)
    case completed
    case failed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [JournalEntryRecord] = []
    @Published var selectedKind: JournalKind?
    @Published var searchText = ""
    @Published var searchTagsText = ""
    @Published var searchStartDate: Date?
    @Published var searchEndDate: Date?
    @Published var syncState: SyncState
    @Published var errorMessage: String?
    @Published var selectedEntryID: UUID?
    @Published var editorSessionID = UUID()
    @Published var selectedEntryIDs = Set<UUID>()
    @Published var isBatchSelecting = false
    @Published var isPresentingBatchOrganizer = false
    @Published var isPresentingEditor = false
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
    }

    let repository: any JournalRepository
    let importStore: any ImportAuditStore
    let searchIndex: JournalSearchIndex
    let paths: JournalPaths
    let deviceID: String
    private let cloudAccountMonitor: CloudAccountMonitor?
    private let searchCoordinator: SearchIndexCoordinator
    private var dayOneTask: Task<Void, Never>?

    init(
        repository: any JournalRepository,
        importStore: any ImportAuditStore,
        searchIndex: JournalSearchIndex,
        paths: JournalPaths,
        cloudAccountMonitor: CloudAccountMonitor?
    ) {
        self.repository = repository
        self.importStore = importStore
        self.searchIndex = searchIndex
        self.paths = paths
        self.cloudAccountMonitor = cloudAccountMonitor
        searchCoordinator = SearchIndexCoordinator(index: searchIndex)
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
        syncState = await cloudAccountMonitor.currentState()
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
        refresh()
    }

    func selectKind(_ kind: JournalKind?) {
        selectedKind = kind
        editingEntry = nil
        isPresentingEditor = false
        endBatchSelection()
        refresh()
        selectedEntryID = entries.first?.id
    }

    func beginNewEntry() {
        editingEntry = nil
        selectedEntryID = nil
        editorSessionID = UUID()
        isPresentingEditor = true
    }

    func selectEntry(_ entryID: UUID?) {
        selectedEntryID = entryID
        guard entryID != nil else { return }
        editingEntry = nil
        isPresentingEditor = false
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
                ).flatMap(\.tags)
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
        do {
            let record = try repository.save(draft, deviceID: deviceID, at: .now)
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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

    func moveToTrash(_ entry: JournalEntryRecord) {
        do {
            try repository.moveToTrash(entryID: entry.id, deviceID: deviceID, at: .now)
            try searchIndex.remove(id: entry.id)
            markLocalMutation()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
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

    func executeDayOneImport() {
        guard let preview = importPreview else { return }
        dayOneTask?.cancel()
        isWorking = true
        importActivity = .importing(completed: 0, total: preview.items.count)
        dayOneTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
        if let archiveURL = importPreview?.archiveURL,
           archiveURL.deletingLastPathComponent() == paths.importStaging {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        importPreview = nil
        importResult = nil
        importActivity = .idle
        isWorking = false
    }

    func prepareBackup() {
        isWorking = true
        defer { isWorking = false }
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

    func restoreBackup(data: Data, mode: RestoreMode) {
        isWorking = true
        defer { isWorking = false }
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
            lastRestoreResult = try JournalRestoreExecutor().execute(
                contents: contents,
                plan: plan,
                repository: restorable,
                deviceID: deviceID,
                at: .now
            )
            markLocalMutation()
            rebuildSearchIndex()
        } catch {
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
