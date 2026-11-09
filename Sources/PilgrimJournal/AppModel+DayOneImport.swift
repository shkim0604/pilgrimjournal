import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
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
            errorMessage = String(localized: "노트북에 넣을 기록을 선택해 주세요.")
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
}
