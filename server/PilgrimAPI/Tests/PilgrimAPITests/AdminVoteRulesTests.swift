#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

/// Deterministic generator for the random tie-break.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class AdminVoteRulesTests: XCTestCase {
    private let a = Fixture.id(101)
    private let b = Fixture.id(102)
    private let c = Fixture.id(103)
    private let d = Fixture.id(104)
    private let e = Fixture.id(105)

    private var everyone: Set<UUID> { [a, b, c, d, e] }

    private func close(
        round: Int, candidates: [UUID], ballots: [UUID: UUID], remaining: Set<UUID>? = nil,
        seed: UInt64 = 1
    ) -> AdminVoteRules.Outcome {
        var rng = SplitMix64(state: seed)
        return AdminVoteRules.close(
            round: round, candidates: candidates, ballots: ballots,
            remainingMembers: remaining ?? everyone, using: &rng)
    }

    // MARK: Starting a vote

    func testStartDependsOnHowManyMembersAreLeft() {
        XCTAssertEqual(AdminVoteRules.start(remainingMembers: []), .deleteGroup)
        XCTAssertEqual(AdminVoteRules.start(remainingMembers: [b]), .appoint(b))
        XCTAssertEqual(
            AdminVoteRules.start(remainingMembers: [c, a, b]), .openVote(candidates: [a, b, c]))
    }

    // MARK: Round 1

    func testRoundOneWithoutBallotsSchedulesDeletion() {
        XCTAssertEqual(close(round: 1, candidates: [a, b, c], ballots: [:]), .scheduleDeletion)
    }

    func testSingleLeaderIsElectedByMajority() {
        let outcome = close(round: 1, candidates: [a, b, c], ballots: [a: b, b: b, c: a])
        XCTAssertEqual(outcome, .elect(b, decidedBy: .majority))
    }

    func testVotingForYourselfCounts() {
        XCTAssertEqual(
            close(round: 1, candidates: [a, b], ballots: [a: a]), .elect(a, decidedBy: .majority))
    }

    func testTieGoesToARunoffBetweenTheTiedOnly() {
        // specs/group-server: 2:2:1 → round 2 between the two with 2 votes.
        let outcome = close(
            round: 1, candidates: [a, b, c, d, e], ballots: [a: a, b: a, c: b, d: b, e: c])
        XCTAssertEqual(outcome, .runoff(candidates: [a, b]))
    }

    // MARK: Round 2

    func testRunoffLeaderIsElected() {
        XCTAssertEqual(
            close(round: 2, candidates: [a, b], ballots: [a: b, c: b, d: a]),
            .elect(b, decidedBy: .majority))
    }

    func testRunoffTieIsBrokenAtRandomAmongTheTied() {
        var winners = Set<UUID>()
        for seed in UInt64(0)..<64 {
            let outcome = close(
                round: 2, candidates: [a, b, c], ballots: [a: a, b: b], seed: seed)
            guard case .elect(let winner, decidedBy: .random) = outcome else {
                return XCTFail("expected a random election, got \(outcome)")
            }
            XCTAssertTrue([a, b].contains(winner))
            winners.insert(winner)
        }
        XCTAssertEqual(winners, [a, b], "both tied candidates can win")
        XCTAssertEqual(
            close(round: 2, candidates: [a, b], ballots: [a: a, b: b], seed: 7),
            close(round: 2, candidates: [a, b], ballots: [a: a, b: b], seed: 7),
            "the injected generator makes the pick reproducible")
    }

    func testRunoffWithoutBallotsPicksARandomRunoffCandidate() {
        var winners = Set<UUID>()
        for seed in UInt64(0)..<64 {
            guard
                case .elect(let winner, decidedBy: .random) = close(
                    round: 2, candidates: [c, d], ballots: [:], seed: seed)
            else { return XCTFail("expected a random election") }
            winners.insert(winner)
        }
        XCTAssertEqual(winners, [c, d])
    }

    // MARK: Members leaving during a vote

    func testBallotsOfDepartedVotersAreDiscarded() {
        // a and b voted for c, but both left; d's ballot for e is the only one left.
        let outcome = close(
            round: 1, candidates: [c, d, e], ballots: [a: c, b: c, d: e], remaining: [c, d, e])
        XCTAssertEqual(outcome, .elect(e, decidedBy: .majority))
    }

    func testDepartedCandidatesLoseTheirVotes() {
        // c led but left; the remaining ballots decide.
        let outcome = close(
            round: 1, candidates: [a, b, c], ballots: [a: c, b: c, d: c, e: b],
            remaining: [a, b, d, e])
        XCTAssertEqual(outcome, .elect(b, decidedBy: .majority))
    }

    func testOnlyVotesForDepartedCandidatesMeansNoVotes() {
        XCTAssertEqual(
            close(round: 1, candidates: [a, b], ballots: [c: a], remaining: [b, c]),
            .scheduleDeletion)
    }

    func testRestartWhenEveryCandidateLeft() {
        XCTAssertEqual(
            close(round: 2, candidates: [a, b], ballots: [c: a], remaining: [e, c, d]),
            .restart(candidates: [c, d, e]))
    }

    func testSoleMemberIsAppointedWhenEveryCandidateLeft() {
        XCTAssertEqual(
            close(round: 1, candidates: [a, b], ballots: [:], remaining: [c]),
            .elect(c, decidedBy: .soleMember))
    }

    func testNoMembersLeftDeletesTheGroup() {
        XCTAssertEqual(
            close(round: 1, candidates: [a], ballots: [a: a], remaining: []), .deleteGroup)
    }

    // MARK: Durations

    func testRoundLengthsAndGrace() {
        XCTAssertEqual(AdminVoteRules.roundLength(1, dayLength: 86_400), 3 * 86_400)
        XCTAssertEqual(AdminVoteRules.roundLength(2, dayLength: 86_400), 86_400)
        XCTAssertEqual(AdminVoteRules.deletionGrace(dayLength: 86_400), 7 * 86_400)
        XCTAssertEqual(AdminVoteRules.roundLength(1, dayLength: 10), 30)
        XCTAssertEqual(AdminVoteRules.deletionGrace(dayLength: 10), 70)
    }
}
#endif
