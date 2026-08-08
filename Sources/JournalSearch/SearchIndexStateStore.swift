import Foundation

public struct SearchIndexLocalState: Codable, Equatable, Sendable {
    public var indexVersion: Int
    public var historyToken: String?
    public var pendingEntryIDs: Set<UUID>

    public init(
        indexVersion: Int = 1,
        historyToken: String? = nil,
        pendingEntryIDs: Set<UUID> = []
    ) {
        self.indexVersion = indexVersion
        self.historyToken = historyToken
        self.pendingEntryIDs = pendingEntryIDs
    }
}

public actor SearchIndexStateStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> SearchIndexLocalState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SearchIndexLocalState()
        }
        return try JSONDecoder().decode(
            SearchIndexLocalState.self,
            from: Data(contentsOf: url)
        )
    }

    public func save(_ state: SearchIndexLocalState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
