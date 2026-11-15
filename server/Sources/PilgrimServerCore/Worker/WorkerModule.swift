import Vapor

/// Worker module — owned by task S5 (openspec/changes/add-private-groups/tasks.md).
///
/// The feature worker jobs not owned by another module: `expiry`, `mediaFiles`, `votes`, `appleRevocation`, `invites`, `retention`. Register each with `app.workerJobs.register(_:)`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum WorkerModule {
    static func register(_ app: Application) throws {
        try app.installLiveAppleTokenRevokerIfConfigured()
        for job in jobs() {
            app.workerJobs.register(job)
        }
    }

    /// Built fresh per application: `.periodic` jobs keep their last-run time in the job.
    static func jobs() -> [WorkerJob] {
        [
            WorkerJob(
                name: "expiry", lockKey: WorkerLockKey.expiry, interval: WorkerInterval.expiry
            ) {
                context in
                try await ExpirySweep.run(on: context.db, now: context.now)
            },
            WorkerJob(
                name: "mediaFiles", lockKey: WorkerLockKey.mediaFiles,
                interval: WorkerInterval.mediaFiles
            ) { context in
                try await MediaFileSweep.run(
                    on: context.db, store: context.application.mediaStore, now: context.now,
                    logger: context.logger)
            },
            WorkerJob(name: "votes", lockKey: WorkerLockKey.votes, interval: WorkerInterval.votes) {
                context in
                try await VoteSweep.run(
                    on: context.db, now: context.now, dayLength: context.config.dayLength,
                    logger: context.logger)
            },
            .periodic(
                name: "appleRevocation", lockKey: WorkerLockKey.appleRevocation,
                period: WorkerInterval.appleRevocation
            ) { context in
                try await AppleRevocationSweep.run(
                    on: context.db, revoker: context.application.appleTokenRevoker,
                    encryptionKey: context.config.appleTokenEncryptionKey, now: context.now,
                    logger: context.logger)
            },
            .periodic(
                name: "invites", lockKey: WorkerLockKey.invites, period: WorkerInterval.invites
            ) {
                context in
                try await InviteSweep.run(
                    on: context.db, now: context.now, dayLength: context.config.dayLength)
            },
            .periodic(
                name: "retention", lockKey: WorkerLockKey.retention,
                period: WorkerInterval.retention
            ) { context in
                try await RetentionSweep.run(on: context.db, now: context.now)
            },
        ]
    }
}
