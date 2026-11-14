import Foundation

/// Electing a new admin after the admin leaves or deletes their account (design.md 5절).
///
/// Every member left at that moment is both a candidate and a voter. Round 1 lasts 3 days:
/// no ballots → the group is deleted after a 7-day grace; one leader → elected; a tie → round 2
/// (1 day) among the tied. Round 2: one leader → elected; a tie or no ballots → random among
/// round-2 candidates. Members who leave mid-vote lose candidacy and their ballot.
public enum AdminVoteRules {
    public enum Decision: String, Equatable, Sendable, Codable {
        case majority
        case random
        /// Only one member was left, so no vote was held.
        case soleMember
    }

    public enum Outcome: Equatable, Sendable {
        case elect(UUID, decidedBy: Decision)
        case runoff(candidates: [UUID])
        /// Round 1 had no ballots: `pendingDeletion` with `deleteAt = now + deletionGrace`.
        case scheduleDeletion
        /// Every candidate left: start round 1 again with these members.
        case restart(candidates: [UUID])
        /// No member left.
        case deleteGroup
    }

    /// What happens when the admin leaves, given who is still a member.
    public enum Start: Equatable, Sendable {
        case deleteGroup
        /// Exactly one member is left; they become admin without a vote.
        case appoint(UUID)
        /// Round 1 with these candidates (sorted for a stable order).
        case openVote(candidates: [UUID])
    }

    public static func start(remainingMembers: Set<UUID>) -> Start {
        switch remainingMembers.count {
        case 0: .deleteGroup
        case 1: .appoint(remainingMembers.first!)
        default: .openVote(candidates: sorted(remainingMembers))
        }
    }

    /// Closes a round.
    ///
    /// - Parameters:
    ///   - round: 1 or 2.
    ///   - candidates: the round's candidates in display order.
    ///   - ballots: voter ID → candidate ID.
    ///   - remainingMembers: who is a member now. Departed voters' ballots and departed
    ///     candidates are ignored.
    ///   - rng: picks the winner of a round-2 tie (inject a seeded generator in tests).
    public static func close(
        round: Int, candidates: [UUID], ballots: [UUID: UUID], remainingMembers: Set<UUID>,
        using rng: inout some RandomNumberGenerator
    ) -> Outcome {
        precondition(round == 1 || round == 2, "admin votes have two rounds")
        guard !remainingMembers.isEmpty else { return .deleteGroup }

        var seen = Set<UUID>()
        let liveCandidates = candidates.filter {
            remainingMembers.contains($0) && seen.insert($0).inserted
        }
        guard !liveCandidates.isEmpty else {
            switch start(remainingMembers: remainingMembers) {
            case .deleteGroup: return .deleteGroup
            case .appoint(let member): return .elect(member, decidedBy: .soleMember)
            case .openVote(let members): return .restart(candidates: members)
            }
        }

        let candidateSet = Set(liveCandidates)
        var tally: [UUID: Int] = [:]
        for (voter, choice) in ballots
        where remainingMembers.contains(voter) && candidateSet.contains(choice) {
            tally[choice, default: 0] += 1
        }

        guard let top = tally.values.max() else {
            if round == 1 { return .scheduleDeletion }
            return .elect(pickRandom(from: liveCandidates, using: &rng), decidedBy: .random)
        }
        let leaders = liveCandidates.filter { tally[$0] == top }
        if leaders.count == 1 { return .elect(leaders[0], decidedBy: .majority) }
        if round == 1 { return .runoff(candidates: leaders) }
        return .elect(pickRandom(from: leaders, using: &rng), decidedBy: .random)
    }

    /// Round 1: 3 days. Round 2: 1 day.
    public static func roundLength(_ round: Int, dayLength: TimeInterval) -> TimeInterval {
        (round == 1 ? 3 : 1) * dayLength
    }

    /// 7 days between `pendingDeletion` and the actual deletion.
    public static func deletionGrace(dayLength: TimeInterval) -> TimeInterval {
        7 * dayLength
    }

    private static func pickRandom(
        from candidates: [UUID], using rng: inout some RandomNumberGenerator
    ) -> UUID {
        candidates[Int.random(in: 0..<candidates.count, using: &rng)]
    }

    private static func sorted(_ members: Set<UUID>) -> [UUID] {
        members.sorted { $0.pilgrimString < $1.pilgrimString }
    }
}
