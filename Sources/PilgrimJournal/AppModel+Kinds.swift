import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

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
        sharedKindDefinition(for: kind) ?? kindCatalog.definition(for: kind)
    }

    func openKindManagement() {
        isPresentingKindManagement = true
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
    /// the next reconcile pass moves whatever is left. Entries that could not
    /// be saved do not stop the rest; they are reported by the thrown
    /// `KindMoveError` once everything else has moved.
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
        flushOpenEditor()
        let now = Date.now
        let service = KindDeletionService()
        var outcome = try service.moveEntries(
            from: kind, to: target, repository: repository, deviceID: deviceID, at: now)
        let rules = try service.retargetRules(
            from: kind, to: target, repository: repository, at: now)
        outcome.retargetedRuleCount = rules.retargetedRuleCount
        outcome.failures += rules.failures
        try applyMovedEntries(outcome.moved)
        if let error = outcome.error { throw error }
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
    func mergeKindCatalogFromCloud() -> Bool {
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
    func reconcileKinds() {
        guard kindCatalog.hasDeletedKinds else { return }
        flushOpenEditor()
        do {
            let outcome = try KindReconciler().reconcile(
                catalog: kindCatalog, repository: repository, deviceID: deviceID, at: .now)
            try applyMovedEntries(outcome.moved)
            if let error = outcome.error { errorMessage = error.localizedDescription }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves what the open editor has not saved yet, so a kind move reads the
    /// latest text and the editor has nothing stale left to write back after
    /// it reloads. Both editors (the macOS inline one and the iOS sheet)
    /// handle the notification synchronously. Skipped inside an entry save,
    /// whose editor is already saving (see `isSavingEntry`).
    func flushOpenEditor() {
        guard !isSavingEntry else { return }
        NotificationCenter.default.post(name: .saveJournalEntry, object: nil)
    }

    /// Tells any editor showing one of `entryIDs` to reload it from the store.
    func requestEditorReload(_ entryIDs: Set<UUID>) {
        guard !entryIDs.isEmpty else { return }
        editorReloadRequest = EditorReloadRequest(entryIDs: entryIDs)
    }

    /// Tells an editor showing a moved entry to reload it, records the local
    /// change for sync, and updates the search index.
    private func applyMovedEntries(_ moved: [JournalEntryRecord]) throws {
        guard !moved.isEmpty else { return }
        editorReloadRequest = EditorReloadRequest(entryIDs: Set(moved.map(\.id)))
        markLocalMutation()
        for record in moved {
            try searchIndex.upsert(record)
        }
    }

    /// Accumulates unknown kind IDs across refreshes so an unknown kind keeps
    /// its sidebar row while another kind is selected.
    func refreshUnknownKinds(from records: [JournalEntryRecord]) {
        var merged = unknownKinds
        for kind in records.map(\.kind)
        where !kindCatalog.isKnown(kind) && !merged.contains(kind) {
            merged.append(kind)
        }
        merged.removeAll { kindCatalog.isKnown($0) }
        if merged != unknownKinds { unknownKinds = merged }
    }
}

extension AppModel {
    /// Kinds a picker may offer. The current kind is kept in front when it is
    /// no longer offered (deleted or unknown) so the selection never vanishes.
    func kindPickerOptions(
        including current: JournalKind? = nil,
        activeOnly: Bool = false
    ) -> [KindDefinition] {
        let base =
            activeOnly ? kindCatalog.activeKinds : kindCatalog.creatableKinds
        guard let current, !base.contains(where: { $0.kind == current }) else {
            return base
        }
        return [kindDefinition(for: current)] + base
    }
}
