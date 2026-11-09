import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
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
        let wasSavingEntry = isSavingEntry
        isSavingEntry = true
        defer { isSavingEntry = wasSavingEntry }
        if let spaceID = sharedSpaceID(for: draft.id)
            ?? (draft.id == nil ? newEntrySharedSpaceID : nil)
        {
            return saveShared(
                draft, in: spaceID, closeEditor: closeEditor, selectSavedEntry: selectSavedEntry)
        }
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
            if !applySavedPrayerRecordInPlace(record) {
                refresh()
            }
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
            || draft.details.hasPrayerChecklistContent
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
            guard let current = entryRecord(id: id), !current.isDeleted else {
                return
            }
        }
        _ = save(draft, closeEditor: false, selectSavedEntry: false)
    }

    func isEntryDeleted(_ entryID: UUID?) -> Bool {
        guard let entryID else { return false }
        return entryRecord(id: entryID)?.isDeleted == true
    }

    /// The entry with `id`, from a shared notebook or the private journal.
    func entryRecord(id: UUID) -> JournalEntryRecord? {
        sharedEntry(id: id) ?? (try? repository.entry(id: id)) ?? nil
    }

    func revisions(for entryID: UUID) -> [EntryRevisionRecord] {
        do {
            if let shared = try sharedRevisions(for: entryID) { return shared }
            return try repository.revisions(entryID: entryID)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func restoreRevision(entryID: UUID, revisionID: UUID) {
        if let spaceID = sharedSpaceID(for: entryID) {
            restoreSharedRevision(entryID: entryID, revisionID: revisionID, in: spaceID)
            return
        }
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
}
