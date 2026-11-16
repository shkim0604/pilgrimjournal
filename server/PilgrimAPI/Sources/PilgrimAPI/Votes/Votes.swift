import Foundation

/// `GET /groups/:id/vote`, `POST /groups/:id/vote/ballot`. Vote counts stay secret; only the
/// number of ballots cast is visible.
public struct VoteResponse: Equatable, Sendable, Codable {
    public var round: Int
    public var startedAt: Date
    public var endsAt: Date
    public var candidates: [UserSummary]
    public var myBallot: UUID?
    public var ballotCount: Int
    public var eligibleCount: Int

    public init(
        round: Int, startedAt: Date, endsAt: Date, candidates: [UserSummary], myBallot: UUID?,
        ballotCount: Int, eligibleCount: Int
    ) {
        self.round = round
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.candidates = candidates
        self.myBallot = myBallot
        self.ballotCount = ballotCount
        self.eligibleCount = eligibleCount
    }
}

/// `POST /groups/:id/vote/ballot`. Changeable until the round closes; voting for yourself is fine.
public struct CastBallotRequest: Equatable, Sendable, Codable {
    public var candidateUserId: UUID

    public init(candidateUserId: UUID) {
        self.candidateUserId = candidateUserId
    }
}
