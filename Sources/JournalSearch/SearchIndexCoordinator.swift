import Foundation
import JournalDomain

public actor SearchIndexCoordinator {
    private let index: JournalSearchIndex
    private var pendingIDs = Set<UUID>()
    private var historyToken: String?

    public init(index: JournalSearchIndex) {
        self.index = index
    }

    public func enqueue(_ entryIDs: some Sequence<UUID>) {
        pendingIDs.formUnion(entryIDs)
    }

    public func drain(
        load: @Sendable (UUID) async throws -> JournalEntryRecord?,
        newHistoryToken: String?
    ) async throws {
        let identifiers = pendingIDs.sorted { $0.uuidString < $1.uuidString }
        for id in identifiers {
            if let entry = try await load(id) {
                try index.upsert(entry)
            } else {
                try index.remove(id: id)
            }
            pendingIDs.remove(id)
        }
        historyToken = newHistoryToken
    }

    public func needsRebuild(expectedHistoryToken: String?) -> Bool {
        historyToken != expectedHistoryToken
    }

    public func rebuild(
        entries: [JournalEntryRecord],
        historyToken: String?
    ) throws {
        try index.rebuild(from: entries)
        self.historyToken = historyToken
        pendingIDs.removeAll()
    }
}
