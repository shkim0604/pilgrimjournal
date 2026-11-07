#if PILGRIM_SWIFTDATA
import Foundation
import JournalDomain
import SwiftData

/// One local SwiftData store per shared space, with the same entry, revision and attachment
/// models as the private journal but never mirrored to CloudKit: family sharing syncs these
/// itself. Leaving or ending a share deletes the space's files.
@MainActor
public final class SwiftDataSharedEntryCacheProvider: SharedEntryCacheProvider {
    private let directory: URL
    private var open: [UUID: SwiftDataJournalRepository] = [:]

    /// `directory` is the account scope's `Shared` folder, so another Apple or iCloud
    /// account never sees this account's shared spaces.
    public init(directory: URL) {
        self.directory = directory
    }

    public func cache(for space: SharedSpaceRecord) throws -> any SharedEntryCache {
        if let repository = open[space.id] { return repository }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schema = Schema(JournalContainerFactory.canonicalModels)
        let configuration = ModelConfiguration(
            space.zoneName,
            schema: schema,
            url: storeURL(for: space),
            cloudKitDatabase: .none
        )
        let repository = SwiftDataJournalRepository(
            container: try ModelContainer(for: schema, configurations: configuration))
        open[space.id] = repository
        return repository
    }

    public func removeCache(for space: SharedSpaceRecord) throws {
        open[space.id] = nil
        let base = storeURL(for: space)
        // SQLite keeps write-ahead and shared-memory files beside the store.
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: base.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func storeURL(for space: SharedSpaceRecord) -> URL {
        directory.appending(path: "\(space.zoneName).store")
    }
}
#endif
