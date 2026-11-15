import Fluent
import Foundation
import Logging
import PilgrimAPI

/// Where the `votes` loop gets randomness for a round-2 tie. The worker uses the system
/// generator; tests inject a fixed sequence.
public typealias RandomSource = @Sendable () -> UInt64

struct SourceRandomNumberGenerator: RandomNumberGenerator {
    let source: RandomSource

    mutating func next() -> UInt64 { source() }
}

/// `votes` (60 s): closes admin votes whose round has ended and deletes `pendingDeletion`
/// groups whose grace period is over (design.md 5절).
///
/// The rules and their effects belong to the Votes and Groups modules (S2):
/// `VoteService.closeDueVotes` applies `AdminVoteRules.close` (elect, runoff, random, restart,
/// deletion grace) and queues the result pushes; `GroupService.deleteDueGroups` removes the
/// groups. This loop only drives them in batches.
public enum VoteSweep {
    public static let batchSize = 100
    /// Batches per iteration, so a backlog cannot hold the lock for long.
    static let maximumBatches = 10

    public static let systemRandom: RandomSource = {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }

    public struct Summary: Equatable, Sendable {
        public var votesClosed = 0
        public var groupsDeleted = 0
    }

    @discardableResult
    public static func run(
        on db: any Database, now: Date, dayLength: TimeInterval,
        random: @escaping RandomSource = systemRandom, logger: Logger
    ) async throws -> Summary {
        var summary = Summary()
        var rng = SourceRandomNumberGenerator(source: random)
        for _ in 0..<maximumBatches {
            let closed = try await VoteService.closeDueVotes(
                dayLength: dayLength, on: db, now: now, limit: batchSize, using: &rng)
            summary.votesClosed += closed
            if closed < batchSize { break }
        }
        for _ in 0..<maximumBatches {
            let deleted = try await GroupService.deleteDueGroups(
                on: db, now: now, limit: batchSize)
            summary.groupsDeleted += deleted.count
            if deleted.count < batchSize { break }
        }
        if summary.votesClosed > 0 || summary.groupsDeleted > 0 {
            logger.info(
                "votes pass",
                metadata: [
                    "closed": "\(summary.votesClosed)", "groupsDeleted": "\(summary.groupsDeleted)",
                ])
        }
        return summary
    }
}
