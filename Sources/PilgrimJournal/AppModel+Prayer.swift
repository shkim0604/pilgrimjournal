import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    /// Every prayer note, paged past the timeline's 500-entry cap, so the
    /// aggregated topic lists cover the whole kind.
    func allPrayerEntries() throws -> [JournalEntryRecord] {
        var all: [JournalEntryRecord] = []
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: .prayer,
                includeDeleted: false,
                after: cursor,
                limit: 500
            )
            all.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    func refreshPrayerAggregates() {
        guard isPrayerKindSelected, !hasActiveSearchFilters, prayerScope != .notes else {
            if !ongoingPrayerItems.isEmpty { ongoingPrayerItems = [] }
            if !answeredPrayerSections.isEmpty { answeredPrayerSections = [] }
            return
        }
        switch prayerScope {
        case .ongoing:
            let items = PrayerTopicAggregator.ongoing(in: entries)
            if items != ongoingPrayerItems { ongoingPrayerItems = items }
            if !answeredPrayerSections.isEmpty { answeredPrayerSections = [] }
        case .answered:
            let sections = PrayerTopicAggregator.answeredByMonth(
                in: entries, calendar: .current)
            if sections != answeredPrayerSections { answeredPrayerSections = sections }
            if !ongoingPrayerItems.isEmpty { ongoingPrayerItems = [] }
        case .notes:
            break
        }
    }

    /// While a 기도중/응답 scope is showing, an editor autosave of one prayer
    /// note only needs that record swapped into the already-loaded array —
    /// repaging the whole kind on every autosave tick would stall typing in
    /// the macOS "aggregate list + inline editor" layout. Returns false when
    /// a full `refresh()` is still required.
    func applySavedPrayerRecordInPlace(_ record: JournalEntryRecord) -> Bool {
        guard isPrayerKindSelected, prayerScope != .notes, !hasActiveSearchFilters,
            record.kind == .prayer, record.deletedAt == nil,
            selectedNotebookName == nil
        else { return false }
        if let index = entries.firstIndex(where: { $0.id == record.id }) {
            entries[index] = record
        } else {
            entries.append(record)
            entries.sort { $0.occurredAt > $1.occurredAt }
        }
        refreshPrayerAggregates()
        return true
    }

    func selectPrayerScope(_ scope: PrayerScope) {
        guard prayerScope != scope else { return }
        prayerScope = scope
        refresh()
    }

    func savePrayerTemplate(name: String, categories: [String]) {
        var catalog = prayerTemplateStore.catalog
        guard catalog.upsert(name: name, categories: categories, at: .now) != nil else {
            return
        }
        prayerTemplateStore.save(catalog)
        prayerTemplates = prayerTemplateStore.catalog.activeTemplates
    }

    func deletePrayerTemplate(id: UUID) {
        var catalog = prayerTemplateStore.catalog
        catalog.delete(id: id, at: .now)
        prayerTemplateStore.save(catalog)
        prayerTemplates = prayerTemplateStore.catalog.activeTemplates
    }

    func mergePrayerTemplatesFromCloud() {
        prayerTemplateStore.mergeFromCloud()
        let active = prayerTemplateStore.catalog.activeTemplates
        if active != prayerTemplates { prayerTemplates = active }
    }

    /// Toggles one prayer topic between 기도중 and 응답, saving behind any open
    /// editor the same way kind moves do: flush first, then ask the editor to
    /// reload so it cannot write the stale topic list back.
    func setPrayerTopicStatus(entryID: UUID, topicID: UUID, status: PrayerStatus) {
        flushOpenEditor()
        do {
            guard var draft = try repository.entry(id: entryID)?.draft,
                let index = draft.details.prayerTopics?.firstIndex(where: { $0.id == topicID }),
                draft.details.prayerTopics?[index].status != status
            else { return }
            var topic = draft.details.prayerTopics?[index] ?? PrayerTopic(text: "")
            topic.status = status
            topic.answeredAt = status == .answered ? .now : nil
            if status == .answered {
                topic.answerOutcome = topic.answerOutcome ?? .yes
            } else {
                topic.answerOutcome = nil
                topic.answerNote = nil
            }
            draft.details.prayerTopics?[index] = topic
            let record = try repository.save(draft, deviceID: deviceID, at: .now)
            try searchIndex.upsert(record)
            editorReloadRequest = EditorReloadRequest(entryIDs: [record.id])
            markLocalMutation()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The three views of the 기도노트 content column.
enum PrayerScope: String, CaseIterable {
    case notes
    case ongoing
    case answered
}
