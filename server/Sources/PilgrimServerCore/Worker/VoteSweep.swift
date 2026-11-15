import Fluent
import Foundation
import Logging
import PilgrimAPI
import SQLKit

/// Where the `votes` loop gets randomness for a round-2 tie. The worker uses the system
/// generator; tests inject a fixed sequence.
public typealias RandomSource = @Sendable () -> UInt64

struct SourceRandomNumberGenerator: RandomNumberGenerator {
    let source: RandomSource

    mutating func next() -> UInt64 { source() }
}

extension VoteSweep {
    public static let systemRandom: RandomSource = {
        var generator = SystemRandomNumberGenerator()
        return generator.next()
    }
}

/// `votes` (60 s): closes admin votes whose round has ended with `AdminVoteRules.close`
/// (design.md 5절), notifies the members, and deletes `pendingDeletion` groups whose grace period
/// is over.
public enum VoteSweep {
    public static let batchSize = 50

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
        let sql = try Sweep.sql(db)

        struct DueVote: Decodable {
            var id: UUID
        }
        let due = try await sql.raw(
            """
            SELECT id FROM admin_votes WHERE status = 'open' AND ends_at <= \(bind: now)
            ORDER BY ends_at, id LIMIT \(bind: batchSize)
            """
        ).all(decoding: DueVote.self)
        var firstError: (any Error)?
        for vote in due {
            do {
                if try await close(
                    voteID: vote.id, on: db, now: now, dayLength: dayLength, random: random)
                {
                    summary.votesClosed += 1
                }
            } catch {
                // One broken group must not stop the others; the iteration still fails below so
                // `worker_heartbeat.last_error` shows it.
                logger.report(error: error)
                firstError = firstError ?? error
            }
        }

        summary.groupsDeleted = try await Sweep.repeatBatches(batchSize: 100) {
            try await sql.raw(
                """
                DELETE FROM groups WHERE id IN (
                    SELECT id FROM groups
                    WHERE status = 'pendingDeletion' AND delete_at <= \(bind: now)
                    ORDER BY delete_at, id LIMIT 100)
                RETURNING id
                """
            ).all(decoding: Sweep.IDRow.self).count
        }
        if let firstError { throw firstError }
        return summary
    }

    /// Closes one vote in its own transaction. Returns false when it was already closed.
    static func close(
        voteID: UUID, on db: any Database, now: Date, dayLength: TimeInterval,
        random: @escaping RandomSource
    ) async throws -> Bool {
        try await db.transaction { tx in
            let sql = try Sweep.sql(tx)
            // Lock the group so leave/vote routes (S2) wait for the result.
            try await sql.raw(
                """
                SELECT g.id FROM groups AS g
                JOIN admin_votes AS v ON v.group_id = g.id
                WHERE v.id = \(bind: voteID) FOR UPDATE OF g
                """
            ).run()
            guard let vote = try await AdminVote.find(voteID, on: tx), vote.status == .open,
                let group = try await Group.find(vote.$group.id, on: tx)
            else { return false }
            let groupID = try group.requireID()

            let members = Set(
                try await Membership.query(on: tx).filter(\.$group.$id == groupID).all()
                    .map { $0.$user.id })
            var ballots: [UUID: UUID] = [:]
            for ballot in try await Ballot.query(on: tx).filter(\.$vote.$id == voteID).all() {
                ballots[ballot.$voter.id] = ballot.$candidate.id
            }
            var rng = SourceRandomNumberGenerator(source: random)
            let outcome = AdminVoteRules.close(
                round: vote.round, candidates: vote.candidateIDs, ballots: ballots,
                remainingMembers: members, using: &rng)

            vote.status = .closed
            vote.closedAt = now
            let sortedMembers = members.sorted { $0.pilgrimString < $1.pilgrimString }

            switch outcome {
            case .elect(let winner, let decision):
                vote.outcome = decision == .random ? .random : .elected
                vote.$electedUser.id = winner
                try await vote.update(on: tx)
                group.$admin.id = winner
                group.status = .active
                group.deleteAt = nil
                group.deletionReason = nil
                try await group.update(on: tx)
                let name = try await User.find(winner, on: tx)?.displayName ?? ""
                try await PushOutbox.enqueue(
                    on: tx, groupEvent: .voteDecided(newAdminName: name), groupID: groupID,
                    now: now)

            case .runoff(let candidates):
                vote.outcome = .runoff
                try await vote.update(on: tx)
                try await openRound(
                    2, group: group, candidates: candidates, eligible: sortedMembers, on: tx,
                    now: now, dayLength: dayLength)
                try await PushOutbox.enqueue(
                    on: tx, groupEvent: .voteRunoff, groupID: groupID, now: now)

            case .restart(let candidates):
                vote.outcome = .restarted
                try await vote.update(on: tx)
                try await openRound(
                    1, group: group, candidates: candidates, eligible: candidates, on: tx,
                    now: now, dayLength: dayLength)
                try await PushOutbox.enqueue(
                    on: tx, groupEvent: .voteStarted, groupID: groupID, now: now)

            case .scheduleDeletion:
                vote.outcome = .noVotes
                try await vote.update(on: tx)
                group.$admin.id = nil
                group.status = .pendingDeletion
                group.deleteAt = now.addingTimeInterval(
                    AdminVoteRules.deletionGrace(dayLength: dayLength))
                group.deletionReason = .noVotes
                try await group.update(on: tx)
                try await PushOutbox.enqueue(
                    on: tx, groupEvent: .deletionScheduled, groupID: groupID, now: now)

            case .deleteGroup:
                // Nobody is left to notify; the cascade removes the vote too.
                try await group.delete(on: tx)
            }
            return true
        }
    }

    private static func openRound(
        _ round: Int, group: Group, candidates: [UUID], eligible: [UUID], on db: any Database,
        now: Date, dayLength: TimeInterval
    ) async throws {
        let groupID = try group.requireID()
        try await AdminVote(
            groupID: groupID, round: round, candidateIDs: candidates, eligibleIDs: eligible,
            startedAt: now,
            endsAt: now.addingTimeInterval(AdminVoteRules.roundLength(round, dayLength: dayLength))
        ).create(on: db)
        if group.status != .voting || group.$admin.id != nil {
            group.status = .voting
            group.$admin.id = nil
            try await group.update(on: db)
        }
    }
}
