import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    func rebuildSearchIndex() {
        do {
            let all = try repository.list(kind: nil, includeDeleted: false, limit: 100_000)
            try searchIndex.rebuild(from: all)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareBackup() async {
        isWorking = true
        lastBackupExportMessage = nil
        dataOperationDescription = String(localized: "백업 데이터 준비 중")
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
        dataOperationDescription = String(localized: "백업 검증 중")
        await Task.yield()
        defer {
            isWorking = false
            dataOperationDescription = nil
        }
        do {
            guard let restorable = repository as? any BackupRestoreRepository else {
                throw JournalError.persistence(
                    String(localized: "현재 저장 adapter는 복원을 지원하지 않습니다.")
                )
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
                dataOperationDescription = String(localized: "현재 상태 안전 백업 중")
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
                ? String(localized: "교체 복원 적용 중")
                : String(localized: "병합 복원 적용 중")
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
                title: mode == .replace
                    ? String(localized: "교체 복원 완료")
                    : String(localized: "병합 복원 완료"),
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
        guard let result else { return String(localized: "복원이 끝났습니다.") }
        return String(
            localized:
                "\(result.restored)개 반영 · \(result.tombstoned)개 휴지통 · 충돌 \(result.conflicts)개"
        )
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
}
