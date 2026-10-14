import Foundation

@MainActor
public struct JournalTagManager {
    public init() {}

    public func rename(
        tag oldName: String,
        to newName: String,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date = .now
    ) throws -> [JournalEntryRecord] {
        try replace(
            tag: oldName,
            with: newName,
            repository: repository,
            deviceID: deviceID,
            at: date
        )
    }

    public func remove(
        tag name: String,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date = .now
    ) throws -> [JournalEntryRecord] {
        try replace(
            tag: name,
            with: nil,
            repository: repository,
            deviceID: deviceID,
            at: date
        )
    }

    private func replace(
        tag oldName: String,
        with newName: String?,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> [JournalEntryRecord] {
        let normalizedOld = normalize(oldName)
        guard !normalizedOld.isEmpty else { return [] }
        let normalizedNew = newName.map(normalize).flatMap { $0.isEmpty ? nil : $0 }
        let entries = try repository.list(
            kind: nil,
            includeDeleted: false,
            limit: 100_000
        )
        var updated: [JournalEntryRecord] = []
        for entry in entries
        where entry.tags.contains(where: { normalize($0) == normalizedOld }) {
            var draft = entry.draft
            draft.tags = draft.tags.compactMap { tag in
                normalize(tag) == normalizedOld ? normalizedNew : tag
            }
            updated.append(
                try repository.save(
                    draft,
                    deviceID: deviceID,
                    at: date
                ))
        }
        return updated
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
    }
}
