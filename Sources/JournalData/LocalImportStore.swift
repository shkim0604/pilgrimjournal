#if PILGRIM_SWIFTDATA
import Foundation
import SwiftData

@MainActor
public final class LocalImportStore: ImportAuditStore {
    private let context: ModelContext

    public init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func begin(
        fingerprint: String,
        displayName: String,
        totalCount: Int
    ) throws -> UUID {
        let job = ImportJobEntity()
        job.stableID = UUID()
        job.archiveFingerprint = fingerprint
        job.archiveDisplayName = displayName
        job.startedAt = .now
        job.statusRaw = ImportJobStatus.importing.rawValue
        job.totalCount = totalCount
        context.insert(job)
        try context.save()
        return job.stableID
    }

    public func record(
        jobID: UUID,
        item: ImportAuditItem,
        rawJSON: Data?
    ) throws {
        let entity = ImportItemEntity()
        entity.stableID = UUID()
        entity.jobID = jobID
        entity.sourceUUID = item.sourceUUID
        entity.entryID = item.entryID
        entity.statusRaw = item.status.rawValue
        entity.message = item.message
        context.insert(entity)

        if let rawJSON {
            let snapshot = SourceSnapshotEntity()
            snapshot.stableID = UUID()
            snapshot.jobID = jobID
            snapshot.sourceUUID = item.sourceUUID
            snapshot.rawJSON = rawJSON
            context.insert(snapshot)
        }
        try context.save()
    }

    public func sourceSnapshots() throws -> [String: Data] {
        let snapshots = try context.fetch(
            FetchDescriptor<SourceSnapshotEntity>()
        )
        var values: [String: Data] = [:]
        for snapshot in snapshots {
            if let rawJSON = snapshot.rawJSON {
                values[snapshot.sourceUUID] = rawJSON
            }
        }
        return values
    }

    public func removeSourceSnapshots(sourceUUIDs: Set<String>) throws {
        guard !sourceUUIDs.isEmpty else { return }
        let snapshots = try context.fetch(
            FetchDescriptor<SourceSnapshotEntity>()
        ).filter { sourceUUIDs.contains($0.sourceUUID) }
        guard !snapshots.isEmpty else { return }
        for snapshot in snapshots {
            context.delete(snapshot)
        }
        try context.save()
    }

    public func finish(
        jobID: UUID,
        status: ImportJobStatus,
        succeeded: Int,
        skipped: Int,
        failed: Int
    ) throws {
        let identifier = jobID
        var descriptor = FetchDescriptor<ImportJobEntity>(
            predicate: #Predicate { job in job.stableID == identifier }
        )
        descriptor.fetchLimit = 1
        guard let job = try context.fetch(descriptor).first else { return }
        job.statusRaw = status.rawValue
        job.finishedAt = .now
        job.successCount = succeeded
        job.skippedCount = skipped
        job.failureCount = failed
        try context.save()
    }
}
#endif
