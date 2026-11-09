import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    func availableTags() -> [String] {
        do {
            return Array(
                Set(
                    try repository.list(
                        kind: nil,
                        includeDeleted: false,
                        limit: 100_000
                    ).flatMap(\.visibleTags)
                )
            ).sorted()
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
}
