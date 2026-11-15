import Fluent
import FluentSQL
import Foundation
import PilgrimAPI
import SQLKit

/// Admin elections (design.md 5절) over `admin_votes` and `ballots`.
///
/// - `GroupService.leave` calls `handOver`, `removeParticipant` and `openVote`.
/// - The worker's `votes` loop (S5) calls `closeDueVotes` and `GroupService.deleteDueGroups`.
/// - Routes call `response` and `castBallot`.
///
/// Every function that changes a vote expects the group row to be locked
/// (`GroupService.lockGroup`) inside the caller's transaction, except `closeDueVotes`, which
/// opens its own transaction per vote.
enum VoteService {
    // MARK: - Opening

    /// The admin left an active group: applies `AdminVoteRules.start`. On `.appoint` the member
    /// becomes admin; on `.openVote` the group goes to `voting` and round 1 opens (members are
    /// notified). On `.deleteGroup` nothing changes — the caller deletes the group.
    static func handOver(
        _ group: Group, remainingMembers: Set<UUID>, dayLength: TimeInterval,
        on db: any Database, now: Date = Date()
    ) async throws -> AdminVoteRules.Start {
        let start = AdminVoteRules.start(remainingMembers: remainingMembers)
        switch start {
        case .deleteGroup:
            break
        case .appoint(let member):
            group.$admin.id = member
            group.status = .active
            try await group.save(on: db)
        case .openVote(let candidates):
            group.$admin.id = nil
            group.status = .voting
            try await group.save(on: db)
            try await openRound(
                1, of: try group.requireID(), candidates: candidates, eligible: candidates,
                dayLength: dayLength, on: db, now: now)
        }
        return start
    }

    /// Inserts an open round and notifies every member (`voteStarted`, or `voteRunoff` for
    /// round 2).
    @discardableResult
    static func openRound(
        _ round: Int, of groupID: UUID, candidates: [UUID], eligible: [UUID],
        dayLength: TimeInterval, on db: any Database, now: Date
    ) async throws -> AdminVote {
        let vote = AdminVote(
            groupID: groupID, round: round, candidateIDs: candidates, eligibleIDs: eligible,
            startedAt: now,
            endsAt: now.addingTimeInterval(AdminVoteRules.roundLength(round, dayLength: dayLength)))
        try await vote.create(on: db)
        try await PushOutbox.enqueue(
            on: db, groupEvent: round == 1 ? .voteStarted : .voteRunoff, groupID: groupID,
            now: now)
        return vote
    }

    /// The group's open round, if any.
    static func openVote(of groupID: UUID, on db: any Database) async throws -> AdminVote? {
        try await AdminVote.query(on: db)
            .filter(\.$group.$id == groupID)
            .filter(\.$status == .open)
            .first()
    }

    /// A member left mid-vote: they stop being a candidate and a voter, and ballots by or for
    /// them are discarded (voters who chose them may vote again). No-op without an open vote.
    static func removeParticipant(
        _ userID: UUID, fromOpenVoteOf groupID: UUID, on db: any Database
    ) async throws {
        let sql = try PushOutbox.sqlDatabase(db)
        try await sql.raw(
            """
            DELETE FROM ballots AS b USING admin_votes AS v
             WHERE b.vote_id = v.id AND v.group_id = \(bind: groupID) AND v.status = 'open'
               AND (b.voter_id = \(bind: userID) OR b.candidate_id = \(bind: userID))
            """
        ).run()
        try await sql.raw(
            """
            UPDATE admin_votes
               SET candidate_ids = array_remove(candidate_ids, \(bind: userID)),
                   eligible_ids = array_remove(eligible_ids, \(bind: userID))
             WHERE group_id = \(bind: groupID) AND status = 'open'
            """
        ).run()
    }

    // MARK: - Reading and voting

    /// `GET /groups/:id/vote`: 404 for non-members and when no round is open.
    static func response(
        for groupID: UUID, viewer: UUID, config: AppConfig, on db: any Database,
        now: Date = Date()
    ) async throws -> VoteResponse {
        _ = try await ContentVisibility.requireMembership(of: viewer, in: groupID, on: db)
        guard let vote = try await openVote(of: groupID, on: db) else {
            throw APIError.notFound("no open admin vote")
        }
        return try await response(vote, viewer: viewer, config: config, on: db, now: now)
    }

    /// `POST /groups/:id/vote/ballot`: casts or changes the viewer's ballot. 409 `VOTE_NOT_OPEN`
    /// without an open round (or once it has ended), 403 when the viewer has no vote in it,
    /// 422 `INVALID_CANDIDATE` for anyone outside the candidates.
    static func castBallot(
        for candidateID: UUID, in groupID: UUID, by viewer: UUID, config: AppConfig,
        on db: any Database, now: Date = Date()
    ) async throws -> VoteResponse {
        let vote = try await db.transaction { tx -> AdminVote in
            try await GroupService.lockGroup(groupID, on: tx)
            _ = try await ContentVisibility.requireMembership(of: viewer, in: groupID, on: tx)
            guard let vote = try await openVote(of: groupID, on: tx), vote.endsAt > now else {
                throw APIError(code: .voteNotOpen, message: "no admin vote is open")
            }
            guard vote.eligibleIDs.contains(viewer) else {
                throw APIError.forbidden("not a voter in this round")
            }
            guard vote.candidateIDs.contains(candidateID),
                try await ContentVisibility.membership(of: candidateID, in: groupID, on: tx) != nil
            else {
                throw APIError(
                    code: .invalidCandidate, message: "not a candidate in this round",
                    field: "candidateUserId")
            }
            let sql = try PushOutbox.sqlDatabase(tx)
            try await sql.raw(
                """
                INSERT INTO ballots (id, vote_id, voter_id, candidate_id, created_at, updated_at)
                VALUES (\(bind: UUID()), \(bind: try vote.requireID()), \(bind: viewer), \
                \(bind: candidateID), now(), now())
                ON CONFLICT (vote_id, voter_id)
                DO UPDATE SET candidate_id = EXCLUDED.candidate_id, updated_at = now()
                """
            ).run()
            return vote
        }
        return try await response(vote, viewer: viewer, config: config, on: db, now: now)
    }

    /// Counts only ballots and voters that are still members; vote counts per candidate stay
    /// secret.
    static func response(
        _ vote: AdminVote, viewer: UUID, config: AppConfig, on db: any Database, now: Date
    ) async throws -> VoteResponse {
        let voteID = try vote.requireID()
        let members = try await GroupService.memberIDs(of: vote.$group.id, on: db)
        let ballots = try await Ballot.query(on: db).filter(\.$vote.$id == voteID).all()
        let liveBallots = ballots.filter { members.contains($0.$voter.id) }
        let candidates = vote.candidateIDs.filter(members.contains)
        let users = try await GroupUserSummaries.load(candidates, config: config, on: db, now: now)
        return VoteResponse(
            round: vote.round, startedAt: vote.startedAt, endsAt: vote.endsAt,
            candidates: candidates.compactMap { users[$0] },
            myBallot: liveBallots.first { $0.$voter.id == viewer }?.$candidate.id,
            ballotCount: liveBallots.count,
            eligibleCount: vote.eligibleIDs.filter(members.contains).count)
    }

    // MARK: - Closing (worker)

    /// Closes up to `limit` open rounds whose `ends_at` has passed, one transaction each.
    /// Returns how many were closed. Safe to run from two workers at once (the group row lock
    /// and the `status = 'open'` re-check make the second one skip).
    @discardableResult
    static func closeDueVotes(
        dayLength: TimeInterval, on db: any Database, now: Date = Date(), limit: Int = 100
    ) async throws -> Int {
        var rng = SystemRandomNumberGenerator()
        return try await closeDueVotes(
            dayLength: dayLength, on: db, now: now, limit: limit, using: &rng)
    }

    static func closeDueVotes(
        dayLength: TimeInterval, on db: any Database, now: Date, limit: Int,
        using rng: inout some RandomNumberGenerator
    ) async throws -> Int {
        let due = try await AdminVote.query(on: db)
            .filter(\.$status == .open)
            .filter(\.$endsAt <= now)
            .sort(\.$endsAt)
            .limit(limit)
            .all()
        var closed = 0
        for vote in due {
            let voteID = try vote.requireID()
            let groupID = vote.$group.id
            // A seeded generator cannot cross into the `@Sendable` transaction closure, so the
            // random pick (only used for a round-2 tie) is drawn up front.
            let seed = UInt64.random(in: .min ... .max, using: &rng)
            let didClose = try await db.transaction { tx -> Bool in
                try await GroupService.lockGroup(groupID, on: tx)
                guard let fresh = try await AdminVote.find(voteID, on: tx),
                    fresh.status == .open, fresh.endsAt <= now
                else { return false }
                var seeded = SeededGenerator(seed: seed)
                _ = try await close(fresh, dayLength: dayLength, on: tx, now: now, using: &seeded)
                return true
            }
            if didClose { closed += 1 }
        }
        return closed
    }

    /// Closes one round with `AdminVoteRules.close` and applies the outcome:
    ///
    /// - `elect` → the winner becomes admin, the group `active`, members get `voteDecided`.
    /// - `runoff` → round 2 (1 day) among the tied, members get `voteRunoff`.
    /// - `scheduleDeletion` → `pendingDeletion` for 7 days (`noVotes`), members notified.
    /// - `restart` → every candidate left; round 1 again with the members now left.
    /// - `deleteGroup` → nobody is left; the group is deleted.
    ///
    /// Call with the group row locked.
    @discardableResult
    static func close(
        _ vote: AdminVote, dayLength: TimeInterval, on db: any Database, now: Date,
        using rng: inout some RandomNumberGenerator
    ) async throws -> AdminVoteRules.Outcome {
        let voteID = try vote.requireID()
        let groupID = vote.$group.id
        let members = try await GroupService.memberIDs(of: groupID, on: db)
        var ballots: [UUID: UUID] = [:]
        for ballot in try await Ballot.query(on: db).filter(\.$vote.$id == voteID).all() {
            ballots[ballot.$voter.id] = ballot.$candidate.id
        }
        let outcome = AdminVoteRules.close(
            round: vote.round, candidates: vote.candidateIDs, ballots: ballots,
            remainingMembers: members, using: &rng)

        vote.status = .closed
        vote.closedAt = now
        switch outcome {
        case .deleteGroup:
            vote.outcome = .groupDeleted
            try await vote.save(on: db)
            try await GroupService.deleteGroup(groupID, on: db)
            return outcome
        case .elect(let winner, let decidedBy):
            vote.outcome = decidedBy == .random ? .random : .elected
            vote.$electedUser.id = winner
        case .runoff:
            vote.outcome = .runoff
        case .scheduleDeletion:
            vote.outcome = .noVotes
        case .restart:
            vote.outcome = .restarted
        }
        try await vote.save(on: db)

        guard let group = try await Group.find(groupID, on: db) else { return outcome }
        switch outcome {
        case .elect(let winner, _):
            group.$admin.id = winner
            group.status = .active
            try await group.save(on: db)
            let name = try await User.find(winner, on: db)?.displayName ?? ""
            try await PushOutbox.enqueue(
                on: db, groupEvent: .voteDecided(newAdminName: name), groupID: groupID, now: now)
        case .runoff(let candidates):
            try await openRound(
                2, of: groupID, candidates: candidates, eligible: sortedIDs(members),
                dayLength: dayLength, on: db, now: now)
        case .restart(let candidates):
            try await openRound(
                1, of: groupID, candidates: candidates, eligible: candidates,
                dayLength: dayLength, on: db, now: now)
        case .scheduleDeletion:
            group.status = .pendingDeletion
            group.deleteAt = now.addingTimeInterval(
                AdminVoteRules.deletionGrace(dayLength: dayLength))
            group.deletionReason = .noVotes
            try await group.save(on: db)
            try await PushOutbox.enqueue(
                on: db, groupEvent: .deletionScheduled, groupID: groupID, now: now)
        case .deleteGroup:
            break
        }
        return outcome
    }

    static func sortedIDs(_ ids: Set<UUID>) -> [UUID] {
        ids.sorted { $0.pilgrimString < $1.pilgrimString }
    }
}

/// SplitMix64, so a value drawn from any generator can seed a `Sendable` one.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
