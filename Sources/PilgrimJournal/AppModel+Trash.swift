import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    func moveToTrash(_ entry: JournalEntryRecord) {
        if let spaceID = sharedSpaceID(for: entry.id) {
            moveSharedEntriesToTrash([entry.id], in: spaceID)
            return
        }
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
        if let spaceID = selectedSharedSpaceID {
            moveSharedEntriesToTrash(entryIDs, in: spaceID)
            endBatchSelection()
            return true
        }

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
                    title: String(localized: "영구 삭제 완료"),
                    message: String(
                        localized: "\(summary.purgedEntryIDs.count)개의 기록을 영구히 삭제했습니다."
                    )
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
    func releaseAttachmentFiles(_ checksums: Set<String>) {
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
    func removePreviewTempFiles(for attachmentIDs: Set<UUID>) {
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
}
