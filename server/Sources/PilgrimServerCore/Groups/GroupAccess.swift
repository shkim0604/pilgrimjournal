import Fluent
import Foundation
import PilgrimAPI
import Vapor

/// Account checks every group route runs before its handler (spec "가입 정보와 정지",
/// "구독 검증과 권한"): the signed-in user still exists, is not suspended, has finished sign-up
/// and — while `SUBSCRIPTION_REQUIRED` is on — is subscribed.
///
/// The loaded `User` is kept on the request (`req.groupCaller`) so handlers do not read it again.
struct GroupAccountGate: AsyncMiddleware {
    struct Requirements: Sendable {
        /// 403 `SIGNUP_REQUIRED` without a display name.
        var signup: Bool
        /// 402 `SUBSCRIPTION_REQUIRED` while `SUBSCRIPTION_REQUIRED=true` and not subscribed.
        var subscription: Bool

        /// `groups/**`, invite accept: signed up and (when required) subscribed.
        static let member = Requirements(signup: true, subscription: true)
        /// `GET /invites/:code`: signed in only; the preview reports `requiresSubscription`.
        static let signedIn = Requirements(signup: false, subscription: false)
    }

    let requirements: Requirements

    init(_ requirements: Requirements) {
        self.requirements = requirements
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let userID = try request.userID
        guard let user = try await User.find(userID, on: request.db) else {
            // A valid token for a deleted account.
            throw APIError.unauthenticated("account no longer exists")
        }
        let now = Date()
        if user.isSuspended(at: now) {
            throw APIError(code: .accountSuspended, message: "account suspended")
        }
        if requirements.signup, !user.profileComplete {
            throw APIError(code: .signupRequired, message: "finish sign-up first")
        }
        if requirements.subscription, request.pilgrimConfig.subscriptionRequired {
            guard try await GroupEntitlement.isSubscribed(userID, on: request.db, now: now) else {
                throw APIError(code: .subscriptionRequired, message: "subscription required")
            }
        }
        request.storage[GroupCallerKey.self] = user
        return try await next.respond(to: request)
    }
}

private struct GroupCallerKey: StorageKey {
    typealias Value = User
}

extension Request {
    /// The user `GroupAccountGate` loaded for this request.
    var groupCaller: User {
        get throws {
            guard let user = storage[GroupCallerKey.self] else {
                throw APIError.unauthenticated()
            }
            return user
        }
    }
}

/// `EntitlementPolicy` over the user's `subscriptions` rows.
enum GroupEntitlement {
    static func isSubscribed(_ userID: UUID, on db: any Database, now: Date) async throws -> Bool {
        let rows = try await AppStoreSubscription.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        return rows.contains {
            EntitlementPolicy.isActive(status: $0.status, expiresAt: $0.expiresAt, now: now)
        }
    }

    /// Whether the app must show the subscription screen before `userID` can join a group.
    static func requiresSubscription(
        _ userID: UUID, config: AppConfig, on db: any Database, now: Date
    ) async throws -> Bool {
        guard config.subscriptionRequired else { return false }
        return try await !isSubscribed(userID, on: db, now: now)
    }
}

/// Group lookups with the error answers of design.md 2절 and 5절, shared by the Groups, Invites
/// and Votes routes (and usable by Posts/Stickers for "author or admin" checks).
enum GroupAccess {
    /// What an admin-only write may do while the group is `pendingDeletion`.
    enum PendingDeletionPolicy {
        /// Refused with 409 `GROUP_PENDING_DELETION` (rename, kick, unban, transfer, new invite).
        case refuse
        /// Allowed (reading lists, revoking an invite).
        case allow
    }

    /// The group and the caller's membership, or 404 `NOT_FOUND` for non-members and unknown
    /// groups alike.
    static func memberGroup(_ groupID: UUID, viewer: UUID, on db: any Database) async throws
        -> (group: Group, membership: Membership)
    {
        let membership = try await ContentVisibility.requireMembership(
            of: viewer, in: groupID, on: db)
        guard let group = try await Group.find(groupID, on: db) else {
            throw APIError.notFound()
        }
        return (group, membership)
    }

    /// Refuses admin-only actions: 409 `ADMIN_VOTE_IN_PROGRESS` while voting (there is no admin),
    /// 409 `GROUP_PENDING_DELETION` when `pendingDeletion` and `policy == .refuse`, otherwise
    /// 403 `FORBIDDEN` unless `viewer` is the admin.
    static func requireAdmin(
        _ group: Group, viewer: UUID, pendingDeletion policy: PendingDeletionPolicy = .refuse
    ) throws {
        switch group.status {
        case .voting:
            throw APIError(
                code: .adminVoteInProgress, message: "an admin election is in progress")
        case .pendingDeletion where policy == .refuse:
            throw APIError(
                code: .groupPendingDeletion, message: "the group is scheduled for deletion")
        case .active, .pendingDeletion:
            break
        }
        guard group.$admin.id == viewer else {
            throw APIError.forbidden("only the group admin can do this")
        }
    }

    /// Whether `viewer` is the admin of an active group (for "author or admin" deletes). False
    /// while voting.
    static func isActingAdmin(_ group: Group, viewer: UUID) -> Bool {
        group.status != .voting && group.$admin.id == viewer
    }

    /// Parses a `:groupID`-style path parameter; an unparsable ID is a plain 404.
    static func uuidParameter(_ name: String, of req: Request) throws -> UUID {
        guard let text = req.parameters.get(name), let id = UUID(uuidString: text) else {
            throw APIError.notFound()
        }
        return id
    }
}
