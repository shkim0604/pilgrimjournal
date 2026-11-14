import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    /// Drops selected ids that the current filter no longer shows.
    ///
    /// The list highlight only covers visible rows, so a stale id would arm the
    /// trash button for a note the user cannot see.
    func pruneSelectionToVisibleEntries() {
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
        selectedSharedSpaceID = nil
        clearGroupSelection()
        refresh()
    }

    func selectKind(_ kind: JournalKind?) {
        selectedKind = kind
        prayerScope = .notes
        selectedNotebookName = nil
        selectedSharedSpaceID = nil
        clearGroupSelection()
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
        selectedSharedSpaceID = nil
        clearGroupSelection()
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
            errorMessage = String(localized: "노트북 이름을 입력해 주세요.")
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

            forgetNotebook(notebook)
            markLocalMutation()
            refresh()
            selectedEntryID = entries.first?.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Drops a notebook name from the catalog (and keeps it from coming back from
    /// iCloud) without touching entries; the caller has already moved them.
    func forgetNotebook(_ notebook: String) {
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
    }

    func beginNewEntry() {
        // A new note belongs to the journal: leave the group feed for the entry list, which
        // the group selection left untouched.
        if selectedGroupID != nil {
            clearGroupSelection()
            refresh()
        }
        editingEntry = nil
        selectedEntryID = nil
        selectedEntryIDs.removeAll()
        newEntryNotebookName = selectedNotebookName
        // Captured now rather than read at save time: the new-note editor still saves
        // on its way out after the sidebar selection has already moved on.
        newEntrySharedSpaceID = selectedSharedSpaceID
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
        if selectedGroupID != nil {
            clearGroupSelection()
            refresh()
        }
        selectedEntryID = nil
        editingEntry = nil
        isPresentingEditor = false
        isPresentingSettings = true
        endBatchSelection()
    }

    // MARK: Groups

    /// Shows a group's feed instead of the entry list. Clears every other sidebar selection
    /// and any open entry, editor or settings, the way `selectSharedSpace` does.
    func selectGroup(_ groupID: UUID) {
        selectedKind = nil
        prayerScope = .notes
        selectedNotebookName = nil
        selectedSharedSpaceID = nil
        newEntryNotebookName = nil
        editingEntry = nil
        isPresentingEditor = false
        isPresentingSettings = false
        endBatchSelection()
        selectedEntryID = nil
        if selectedGroupID != groupID {
            selectedGroupPostID = nil
        }
        selectedGroupID = groupID
    }

    /// Opens a post of the selected group in the detail column (nil closes it).
    func selectGroupPost(_ postID: UUID?) {
        guard selectedGroupID != nil else { return }
        selectedGroupPostID = postID
    }

    func clearGroupSelection() {
        if selectedGroupID != nil { selectedGroupID = nil }
        if selectedGroupPostID != nil { selectedGroupPostID = nil }
    }

    /// Follows a tapped group notification. The Daily Report screen arrives with A7; until
    /// then that route leaves the selection alone.
    func openGroupNotificationRoute(_ route: GroupNotificationRoute) {
        switch route {
        case .post(let groupID, let postID):
            selectGroup(groupID)
            selectGroupPost(postID)
        case .group(let groupID):
            selectGroup(groupID)
        case .dailyReport:
            break
        }
    }

    func beginBatchSelection() {
        selectedEntryIDs = selectedEntryID.map { Set([$0]) } ?? []
        isBatchSelecting = true
        // Batch mode always acts on the note list; leaving an aggregate scope
        // also drops the uncapped all-prayer-notes array it loaded.
        if prayerScope != .notes {
            prayerScope = .notes
            refresh()
        }
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

    func refreshNotebookCatalog(from records: [JournalEntryRecord]) {
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

    func mergeNotebookCatalogFromCloud() {
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

    static func mergedNotebookNames(
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

    static func containsNotebook(
        _ name: String,
        in names: [String]
    ) -> Bool {
        names.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
