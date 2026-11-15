import Fluent
import Foundation
import PilgrimAPI
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Admin elections end to end (design.md 5절): ballots over HTTP, closing through
/// `VoteService.closeDueVotes` as the worker does.
final class VoteServiceTests: DatabaseTestCase {
    let day: TimeInterval = 86_400

    /// A group whose admin has left, so round 1 is open among `members`.
    private func votingGroup(_ names: [String]) async throws -> (Group, [User]) {
        let admin = try await fixtures.user("떠난 관리자")
        var members: [User] = []
        for name in names { members.append(try await fixtures.user(name)) }
        let group = try await fixtures.group(admin: admin, members: members)
        let outcome = try await GroupService.leave(
            admin.id!, group: group.id!, dayLength: day, on: db)
        guard case .voteStarted = outcome else {
            XCTFail("expected a vote, got \(outcome)")
            return (group, members)
        }
        return (group, members)
    }

    private func ballot(_ voter: User, for candidate: User, in group: Group) async throws
        -> XCTHTTPResponse
    {
        try await send(
            .POST, "api/v1/groups/\(group.id!.pilgrimString)/vote/ballot", as: voter,
            json: CastBallotRequest(candidateUserId: candidate.id!))
    }

    /// How far the simulated clock has moved; each `closeAll` moves it 10 more days, past any
    /// round the previous call opened.
    private var clockOffset: TimeInterval = 0

    /// Closes every open round as if `ends_at` had passed.
    private func closeAll(random: UInt64 = 0) async throws -> Int {
        var rng = FixedRandom(value: random)
        clockOffset += 10 * day
        return try await VoteService.closeDueVotes(
            dayLength: day, on: db, now: Date().addingTimeInterval(clockOffset), limit: 100,
            using: &rng)
    }

    func testBallotsCanChangeAndCountsStaySecret() async throws {
        let (group, members) = try await votingGroup(["가", "나", "다"])
        let (a, b, c) = (members[0], members[1], members[2])

        var response = try await ballot(a, for: b, in: group)
        expectEqual(response.status, .ok, response.body.string)
        var vote = try decode(VoteResponse.self, from: response)
        expectEqual(vote.myBallot, b.id)
        expectEqual(vote.ballotCount, 1)
        expectEqual(vote.eligibleCount, 3)

        response = try await ballot(a, for: a, in: group)
        vote = try decode(VoteResponse.self, from: response)
        expectEqual(vote.myBallot, a.id, "voting for yourself is fine")
        expectEqual(vote.ballotCount, 1)

        let seenByC = try decode(
            VoteResponse.self,
            from: try await send(.GET, "api/v1/groups/\(group.id!.pilgrimString)/vote", as: c))
        expectNil(seenByC.myBallot)
        expectEqual(seenByC.ballotCount, 1)
    }

    func testBallotErrors() async throws {
        let (group, members) = try await votingGroup(["가", "나"])
        let outsider = try await fixtures.user()
        try assertError(try await ballot(members[0], for: outsider, in: group), .invalidCandidate)

        let admin = try await fixtures.user()
        let calm = try await fixtures.group(admin: admin, members: [members[0]])
        try assertError(try await ballot(members[0], for: admin, in: calm), .voteNotOpen)
        try assertError(
            try await send(.GET, "api/v1/groups/\(calm.id!.pilgrimString)/vote", as: admin),
            .notFound)
    }

    func testMajorityElects() async throws {
        let (group, members) = try await votingGroup(["가", "나", "다"])
        let (a, b, c) = (members[0], members[1], members[2])
        _ = try await ballot(a, for: b, in: group)
        _ = try await ballot(b, for: b, in: group)
        _ = try await ballot(c, for: a, in: group)
        try await PushOutboxEntry.query(on: db).delete()

        expectEqual(try await closeAll(), 1)
        let reloaded = try unwrap(try await Group.find(group.id, on: db))
        expectEqual(reloaded.$admin.id, b.id)
        expectEqual(reloaded.status, .active)
        let closed = try unwrap(try await AdminVote.query(on: db).first())
        expectEqual(closed.outcome, .elected)
        expectEqual(closed.$electedUser.id, b.id)
        let pushes = try await PushOutboxEntry.query(on: db).all()
        expectEqual(pushes.count, 3)
        expectEqual(pushes.first?.payload.pilgrim.kind, .voteDecided)
        expectEqual(try await closeAll(), 0, "closing again does nothing")
    }

    func testTieGoesToRunoffThenRandom() async throws {
        let (group, members) = try await votingGroup(["가", "나", "다"])
        let (a, b, c) = (members[0], members[1], members[2])
        _ = try await ballot(a, for: a, in: group)
        _ = try await ballot(b, for: b, in: group)

        expectEqual(try await closeAll(), 1)
        let round2 = try unwrap(try await VoteService.openVote(of: group.id!, on: db))
        expectEqual(round2.round, 2)
        expectEqual(Set(round2.candidateIDs), [a.id!, b.id!])
        expectEqual(Set(round2.eligibleIDs), [a.id!, b.id!, c.id!])
        expectEqual(round2.endsAt.timeIntervalSince(round2.startedAt), day, accuracy: 1)
        try assertError(try await ballot(c, for: c, in: group), .invalidCandidate)

        // Nobody votes in round 2: random among its candidates.
        expectEqual(try await closeAll(), 1)
        let reloaded = try unwrap(try await Group.find(group.id, on: db))
        expectTrue([a.id!, b.id!].contains(try unwrap(reloaded.$admin.id)))
        expectEqual(reloaded.status, .active)
        let last = try await AdminVote.query(on: db).filter(\.$round == 2).first()
        expectEqual(last?.outcome, .random)
    }

    func testNoBallotsSchedulesDeletion() async throws {
        let (group, _) = try await votingGroup(["가", "나"])
        expectEqual(try await closeAll(), 1)
        let reloaded = try unwrap(try await Group.find(group.id, on: db))
        expectEqual(reloaded.status, .pendingDeletion)
        expectEqual(reloaded.deletionReason, .noVotes)
        expectNotNil(reloaded.deleteAt)

        let deleted = try await GroupService.deleteDueGroups(
            on: db, now: Date().addingTimeInterval(30 * day))
        expectEqual(deleted, [group.id!])
        expectNil(try await Group.find(group.id, on: db))
    }

    func testLeavingMidVoteDropsCandidacyAndBallots() async throws {
        let (group, members) = try await votingGroup(["가", "나", "다"])
        let (a, b, c) = (members[0], members[1], members[2])
        _ = try await ballot(a, for: b, in: group)
        _ = try await ballot(b, for: b, in: group)
        _ = try await ballot(c, for: a, in: group)

        _ = try await GroupService.leave(b.id!, group: group.id!, dayLength: day, on: db)
        let vote = try unwrap(try await VoteService.openVote(of: group.id!, on: db))
        expectEqual(Set(vote.candidateIDs), [a.id!, c.id!])
        expectEqual(try await Ballot.query(on: db).count(), 1, "only c's ballot for a is left")

        expectEqual(try await closeAll(), 1)
        expectEqual(try await Group.find(group.id, on: db)?.$admin.id, a.id)
    }

    func testEveryCandidateGoneRestartsWithNewMembersOrDeletes() async throws {
        let (group, members) = try await votingGroup(["가", "나"])
        // Simulate candidates who left without the usual clean-up (e.g. account cascade):
        // the round's candidates are no longer members, two new members are.
        let x = try await fixtures.user("새1")
        let y = try await fixtures.user("새2")
        try await fixtures.join(x, group)
        try await fixtures.join(y, group)
        try await Membership.query(on: db)
            .filter(\.$user.$id ~~ members.map { $0.id! })
            .delete()

        expectEqual(try await closeAll(), 1)
        let restarted = try unwrap(try await VoteService.openVote(of: group.id!, on: db))
        expectEqual(restarted.round, 1)
        expectEqual(Set(restarted.candidateIDs), [x.id!, y.id!])

        try await Membership.query(on: db).filter(\.$group.$id == group.id!).delete()
        expectEqual(try await closeAll(), 1)
        expectNil(try await Group.find(group.id, on: db))
    }
}
