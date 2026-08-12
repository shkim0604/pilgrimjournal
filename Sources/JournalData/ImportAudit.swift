import Foundation

public enum ImportJobStatus: String, Codable, Sendable {
    case analyzing
    case ready
    case importing
    case completed
    case cancelled
    case failed
}

public enum ImportItemStatus: String, Codable, Sendable {
    case pending
    case imported
    case skipped
    case failed
}

public struct ImportAuditItem: Sendable {
    public var sourceUUID: String
    public var entryID: UUID?
    public var status: ImportItemStatus
    public var message: String?

    public init(
        sourceUUID: String,
        entryID: UUID?,
        status: ImportItemStatus,
        message: String? = nil
    ) {
        self.sourceUUID = sourceUUID
        self.entryID = entryID
        self.status = status
        self.message = message
    }
}

@MainActor
public protocol ImportAuditStore: AnyObject {
    func begin(fingerprint: String, displayName: String, totalCount: Int) throws -> UUID
    func record(jobID: UUID, item: ImportAuditItem, rawJSON: Data?) throws
    func sourceSnapshots() throws -> [String: Data]
    func finish(
        jobID: UUID,
        status: ImportJobStatus,
        succeeded: Int,
        skipped: Int,
        failed: Int
    ) throws
    /// Drops the retained raw Day One JSON for the given source UUIDs. Used
    /// after a permanent delete so the "purged" entry's full body doesn't
    /// linger on disk (and in future backups) as a source snapshot. Leaves
    /// the `ImportItemEntity` audit log — what happened during import —
    /// untouched.
    func removeSourceSnapshots(sourceUUIDs: Set<String>) throws
}

public struct ImportAuditSnapshot: Sendable {
    public var jobs: [UUID: ImportJobStatus] = [:]
    public var items: [UUID: [ImportAuditItem]] = [:]
    public var sourceSnapshots: [String: Data] = [:]

    public init() {}
}

@MainActor
public final class InMemoryImportStore: ImportAuditStore {
    public private(set) var snapshot = ImportAuditSnapshot()

    public init() {}

    public func begin(
        fingerprint: String,
        displayName: String,
        totalCount: Int
    ) throws -> UUID {
        let id = UUID()
        snapshot.jobs[id] = .importing
        snapshot.items[id] = []
        return id
    }

    public func record(
        jobID: UUID,
        item: ImportAuditItem,
        rawJSON: Data?
    ) throws {
        snapshot.items[jobID, default: []].append(item)
        if let rawJSON { snapshot.sourceSnapshots[item.sourceUUID] = rawJSON }
    }

    public func sourceSnapshots() -> [String: Data] {
        snapshot.sourceSnapshots
    }

    public func removeSourceSnapshots(sourceUUIDs: Set<String>) throws {
        for sourceUUID in sourceUUIDs {
            snapshot.sourceSnapshots.removeValue(forKey: sourceUUID)
        }
    }

    public func finish(
        jobID: UUID,
        status: ImportJobStatus,
        succeeded: Int,
        skipped: Int,
        failed: Int
    ) throws {
        snapshot.jobs[jobID] = status
    }
}
