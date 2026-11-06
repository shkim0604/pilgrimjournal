import Foundation
import JournalData
import JournalDomain
import JournalSearch

// Shared notebooks in the journal UI. A shared notebook is a third kind of sidebar
// selection next to kinds and notebooks; its entries live in their own store (see
// `FamilySharingController`), so every entry operation in AppModel asks
// `sharedSpaceID(for:)` first and comes here for shared entries.

extension AppModel {
    /// Sharing needs iCloud: the controller exists only for iCloud scopes.
    var canShare: Bool {
        #if PILGRIM_SWIFTDATA
        familySharing != nil
        #else
        false
        #endif
    }

    var selectedSharedSpace: SharedSpaceRecord? {
        #if PILGRIM_SWIFTDATA
        selectedSharedSpaceID.flatMap { familySharing?.space($0) }
        #else
        nil
        #endif
    }

    var selectedSharedSpaceTitle: String? {
        guard let space = selectedSharedSpace else { return nil }
        let name = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "공유 노트북") : name
    }

    /// The shared notebook holding `entryID`, or nil for private entries.
    func sharedSpaceID(for entryID: UUID?) -> UUID? {
        #if PILGRIM_SWIFTDATA
        guard let entryID else { return nil }
        return familySharing?.spaceID(containing: entryID)
        #else
        return nil
        #endif
    }

    func sharedEntry(id: UUID) -> JournalEntryRecord? {
        #if PILGRIM_SWIFTDATA
        familySharing?.entry(id: id)
        #else
        nil
        #endif
    }

    /// The history of a shared entry, or nil when `entryID` is private.
    func sharedRevisions(for entryID: UUID) throws -> [EntryRevisionRecord]? {
        #if PILGRIM_SWIFTDATA
        guard let spaceID = sharedSpaceID(for: entryID), let sharing = familySharing else {
            return nil
        }
        return try sharing.revisions(entryID: entryID, in: spaceID)
        #else
        return nil
        #endif
    }

    func selectSharedSpace(_ spaceID: UUID) {
        selectedKind = nil
        selectedNotebookName = nil
        selectedSharedSpaceID = spaceID
        editingEntry = nil
        isPresentingEditor = false
        endBatchSelection()
        refresh()
        selectedEntryID = entries.first?.id
        #if PILGRIM_SWIFTDATA
        Task { await familySharing?.fetchNow() }
        #endif
    }

    func refreshSharedSpaceEntries(_ spaceID: UUID) {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing, sharing.space(spaceID) != nil else {
            selectedSharedSpaceID = nil
            refresh()
            return
        }
        var list = sharing.entries(in: spaceID)
        // Shared entries are not in the search index; a plain text filter is enough
        // for one notebook.
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.body.localizedCaseInsensitiveContains(query)
            }
        }
        entries = list
        for entry in list where sharedEditBases[entry.id] == nil {
            sharedEditBases[entry.id] = entry.currentRevisionID
        }
        pruneSelectionToVisibleEntries()
        #endif
    }

    // MARK: Editing

    func saveShared(
        _ draft: JournalEntryDraft,
        in spaceID: UUID,
        closeEditor: Bool,
        selectSavedEntry: Bool
    ) -> JournalEntryRecord? {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing else { return nil }
        var outgoing = draft
        // A shared notebook is its own place; private notebook tags don't apply.
        outgoing.notebookName = nil
        let base = draft.id.flatMap { sharedEditBases[$0] }
        let mergesRemoteChange =
            base != nil && draft.id.flatMap { sharing.entry(id: $0) }?.currentRevisionID != base
        isApplyingLocalSharedEdit = true
        defer { isApplyingLocalSharedEdit = false }
        do {
            let record = try sharing.save(
                outgoing,
                kind: sharedKindLabel(for: outgoing.kind),
                in: spaceID,
                basedOn: base
            )
            sharedEditBases[record.id] = record.currentRevisionID
            if selectSavedEntry { selectedEntryID = record.id }
            if closeEditor {
                editingEntry = nil
                isPresentingEditor = false
            }
            refresh()
            // Someone else's change was merged in; show the editor the combined text.
            if mergesRemoteChange { requestEditorReload([record.id]) }
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        #else
        return nil
        #endif
    }

    func moveSharedEntriesToTrash(_ entryIDs: Set<UUID>, in spaceID: UUID) {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing else { return }
        isApplyingLocalSharedEdit = true
        defer { isApplyingLocalSharedEdit = false }
        do {
            for entryID in entryIDs {
                try sharing.moveToTrash(entryID: entryID, in: spaceID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        if let selectedEntryID, entryIDs.contains(selectedEntryID) {
            self.selectedEntryID = nil
            editingEntry = nil
            isPresentingEditor = false
        }
        refresh()
        #endif
    }

    func restoreSharedRevision(entryID: UUID, revisionID: UUID, in spaceID: UUID) {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing, let current = sharing.entry(id: entryID) else { return }
        isApplyingLocalSharedEdit = true
        defer { isApplyingLocalSharedEdit = false }
        do {
            let restored = try sharing.restoreRevision(
                entryID: entryID,
                revisionID: revisionID,
                kind: sharedKindLabel(for: current.kind),
                in: spaceID
            )
            sharedEditBases[entryID] = restored.currentRevisionID
            selectedEntryID = restored.id
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    /// Another member's change (or a share that went away) arrived. An open editor first
    /// saves what it has, which merges with the new version, then reloads the result.
    func sharedSpacesDidChange() {
        #if PILGRIM_SWIFTDATA
        guard !isApplyingLocalSharedEdit, let sharing = familySharing,
            let spaceID = selectedSharedSpaceID
        else { return }
        guard sharing.space(spaceID) != nil else {
            selectedSharedSpaceID = nil
            selectedEntryID = nil
            editingEntry = nil
            isPresentingEditor = false
            refresh()
            return
        }
        let changed = Set(
            sharing.entries(in: spaceID).filter { entry in
                sharedEditBases[entry.id].map { $0 != entry.currentRevisionID } ?? false
            }.map(\.id))
        if !changed.isEmpty {
            flushOpenEditor()
            for entryID in changed {
                if let current = sharing.entry(id: entryID) {
                    sharedEditBases[entryID] = current.currentRevisionID
                }
            }
            requestEditorReload(changed)
        }
        refresh()
        #endif
    }

    // MARK: Sharing

    /// Moves every entry of a notebook into a new share and opens the invitation sheet.
    func shareNotebook(named name: String) async {
        let entries = privateEntries {
            $0.notebookName?.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let entries else { return }
        await shareEntries(entries, named: name, scope: .notebook) {
            self.forgetNotebook(name)
        }
    }

    /// Moves one entry into its own share and opens the invitation sheet.
    func shareEntry(_ entry: JournalEntryRecord) async {
        let name =
            entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "공유 노트") : entry.title
        await shareEntries([entry], named: name, scope: .entry) {}
    }

    /// Ends a share this user owns. Its entries come back into the journal first (into a
    /// notebook of the same name), then the server copies are removed for everyone.
    func stopSharing(_ spaceID: UUID) async {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing, let space = sharing.space(spaceID),
            let journal = repository as? any SharedEntryCache
        else { return }
        flushOpenEditor()
        do {
            let notebook = space.scope == .notebook ? createNotebook(named: space.name) : nil
            for (entry, revisions) in try sharing.contents(of: spaceID) {
                for revision in revisions { try journal.importRevision(revision) }
                var returned = entry
                returned.tags = NotebookTagCodec.assigning(notebook, to: entry.tags)
                try journal.upsertSynced(returned)
                try searchIndex.upsert(returned)
            }
            markLocalMutation()
            try await sharing.stopSharing(spaceID)
            if let notebook {
                selectNotebook(notebook)
            } else {
                selectKind(nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    /// Leaves a share someone else owns, optionally keeping a copy in the journal.
    func leaveSharedSpace(_ spaceID: UUID, keepingCopy: Bool) async {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing, let space = sharing.space(spaceID) else { return }
        flushOpenEditor()
        do {
            if keepingCopy {
                let notebook = createNotebook(named: space.name)
                for entry in sharing.entries(in: spaceID) {
                    var copy = entry.draft
                    copy.id = nil
                    copy.sourceUUID = nil
                    copy.sourceMetadata = nil
                    if !kindCatalog.isKnown(copy.kind) { copy.kind = defaultKindForNewEntry }
                    copy.notebookName = notebook
                    let saved = try repository.save(copy, deviceID: deviceID, at: .now)
                    try searchIndex.upsert(saved)
                }
                markLocalMutation()
            }
            try await sharing.leave(spaceID)
            selectKind(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    func manageSharing(of spaceID: UUID) async {
        #if PILGRIM_SWIFTDATA
        do {
            try await familySharing?.manageShare(of: spaceID)
        } catch {
            errorMessage = error.localizedDescription
        }
        #endif
    }

    // MARK: Helpers

    /// The label to send with a shared entry, or nil to keep the one it has when this
    /// device doesn't know the kind (someone else's custom kind).
    private func sharedKindLabel(for kind: JournalKind) -> SharedKindSnapshot? {
        kindCatalog.isKnown(kind) ? SharedKindSnapshot(kindDefinition(for: kind)) : nil
    }

    /// How to show a kind this device's catalog doesn't know, from the label shared
    /// entries carry, or nil when no shared entry has it either.
    func sharedKindDefinition(for kind: JournalKind) -> KindDefinition? {
        #if PILGRIM_SWIFTDATA
        guard !kindCatalog.isKnown(kind), let label = familySharing?.kindSnapshot(for: kind) else {
            return nil
        }
        return KindDefinition(
            kind: kind,
            name: label.name,
            colorToken: label.colorToken,
            iconToken: label.iconToken,
            order: .max,
            state: .active,
            updatedAt: .distantPast,
            modifiedByDeviceID: ""
        )
        #else
        return nil
        #endif
    }

    /// Every live private entry matching `filter`, or nil after reporting an error.
    private func privateEntries(where filter: (JournalEntryRecord) -> Bool) -> [JournalEntryRecord]?
    {
        do {
            var result: [JournalEntryRecord] = []
            var cursor: JournalTimelineCursor?
            repeat {
                let page = try repository.page(
                    kind: nil, includeDeleted: false, after: cursor, limit: 500)
                result += page.entries.filter(filter)
                cursor = page.nextCursor
            } while cursor != nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func shareEntries(
        _ entries: [JournalEntryRecord],
        named name: String,
        scope: SharedSpaceRecord.Scope,
        afterMove: () -> Void
    ) async {
        #if PILGRIM_SWIFTDATA
        guard let sharing = familySharing else {
            errorMessage = String(localized: "공유하려면 iCloud에 연결되어 있어야 합니다.")
            return
        }
        // Photos don't sync to shared notebooks yet; moving would leave them behind.
        guard entries.allSatisfy({ attachments(for: $0.id).isEmpty }) else {
            errorMessage = String(localized: "사진이 들어 있는 기록은 아직 공유할 수 없습니다.")
            return
        }
        flushOpenEditor()
        isWorking = true
        defer { isWorking = false }
        do {
            let items = try entries.map { entry in
                var moved = entry
                moved.tags = NotebookTagCodec.assigning(nil, to: entry.tags)
                return (
                    entry: moved,
                    revisions: try repository.revisions(entryID: entry.id),
                    kind: SharedKindSnapshot(kindDefinition(for: entry.kind))
                )
            }
            isApplyingLocalSharedEdit = true
            let space = try await sharing.share(named: name, scope: scope, entries: items)
            isApplyingLocalSharedEdit = false
            // The share holds the entries now; take them out of the private journal.
            let ids = Set(entries.map(\.id))
            for id in ids {
                try repository.moveToTrash(entryID: id, deviceID: deviceID, at: .now)
                try? searchIndex.remove(id: id)
            }
            _ = try repository.purgeEntries(ids: ids)
            afterMove()
            markLocalMutation()
            selectSharedSpace(space.id)
        } catch {
            isApplyingLocalSharedEdit = false
            errorMessage = error.localizedDescription
        }
        #endif
    }
}
