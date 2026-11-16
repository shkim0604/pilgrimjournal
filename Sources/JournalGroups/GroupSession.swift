import Foundation
import PilgrimAPI

/// Whether this device holds a usable group session.
public enum GroupSessionState: Equatable, Sendable {
    case notSignedIn
    /// `userID` is the group-server user (`MeResponse.id`).
    case signedIn(userID: UUID)
}

/// Owns the group-server tokens of one journal user (design.md 3절 "세션 토큰").
///
/// - Tokens persist through `GroupCredentialStoring` (the app's Keychain adapter).
/// - `validAccessToken()` refreshes ahead of expiry; `refreshedAccessToken(replacing:)` is the
///   401 path. Both share one in-flight refresh: every caller waiting on an expired token gets
///   the same new token, and only one `POST /auth/refresh` goes out.
/// - A refresh the server rejects (`REFRESH_TOKEN_INVALID`, `REFRESH_TOKEN_REUSED`, any 401)
///   clears only this group session and moves to `.notSignedIn` with `needsSignInAgain`
///   ("그룹에 다시 로그인해 주세요"); the journal session is never touched. An offline or 5xx
///   refresh keeps the tokens so a later call can try again.
public actor GroupSession {
    public typealias Refresher = @Sendable (RefreshRequest) async throws -> AuthSessionResponse

    /// The journal session's Apple user hash (the Keychain account).
    public nonisolated let account: String
    /// Sent as `installationId` with sign-in, refresh and logout.
    public nonisolated let installationID: UUID

    private let store: any GroupCredentialStoring
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval

    private var credential: GroupCredential?
    private var refreshTask: Task<GroupCredential, any Error>?
    /// Bumped on every sign-in and sign-out so a refresh that finishes afterwards is ignored.
    private var generation = 0
    private var observers: [UUID: AsyncStream<GroupSessionState>.Continuation] = [:]

    /// True after the server rejected the session; false again after sign-in or `signOut()`.
    public private(set) var needsSignInAgain = false

    /// - Parameters:
    ///   - refreshLeeway: refresh when the access token expires within this many seconds.
    ///   - refresher: sends `POST /auth/refresh` (`URLSessionGroupAPI` passes its own client).
    public init(
        account: String, installationID: UUID, store: any GroupCredentialStoring,
        refreshLeeway: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() },
        refresher: @escaping Refresher
    ) {
        self.account = account
        self.installationID = installationID
        self.store = store
        self.refreshLeeway = refreshLeeway
        self.now = now
        self.refresher = refresher
        self.credential = (try? store.loadCredential(account: account)) ?? nil
    }

    // MARK: State

    public var state: GroupSessionState {
        credential.map { .signedIn(userID: $0.userId) } ?? .notSignedIn
    }

    public var isSignedIn: Bool { credential != nil }

    /// The stored tokens (logout needs the refresh token).
    public var currentCredential: GroupCredential? { credential }

    /// The current state first, then every change, until the consumer stops listening.
    public func stateUpdates() -> AsyncStream<GroupSessionState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: GroupSessionState.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func setCredential(_ new: GroupCredential?) {
        let before = state
        credential = new
        let after = state
        guard before != after else { return }
        for observer in observers.values { observer.yield(after) }
    }

    // MARK: Sign-in and sign-out

    /// Stores a session from `auth/apple`, `auth/dev` or `auth/refresh`. A Keychain failure
    /// keeps the session in memory for this launch rather than failing the sign-in.
    public func start(_ response: AuthSessionResponse) {
        generation += 1
        refreshTask = nil
        needsSignInAgain = false
        let new = GroupCredential(response)
        try? store.saveCredential(new, account: account)
        setCredential(new)
    }

    /// Forgets the group session (logout, account deletion). The journal session stays.
    public func signOut() {
        clear(needsSignInAgain: false)
    }

    /// Forgets a session the server no longer accepts and asks for group sign-in again.
    public func expire() {
        clear(needsSignInAgain: true)
    }

    private func clear(needsSignInAgain: Bool) {
        generation += 1
        refreshTask = nil
        self.needsSignInAgain = needsSignInAgain
        try? store.deleteCredential(account: account)
        setCredential(nil)
    }

    // MARK: Tokens

    /// An access token to send now, refreshed first when it is about to expire.
    public func validAccessToken() async throws(GroupAPIError) -> String {
        guard let credential else { throw .notSignedIn }
        if credential.refreshTokenExpiresAt <= now() {
            expire()
            throw .notSignedIn
        }
        if credential.accessTokenExpiresAt > now().addingTimeInterval(refreshLeeway) {
            return credential.accessToken
        }
        return try await refreshedAccessToken(replacing: credential.accessToken)
    }

    /// The token to retry with after `rejectedToken` got a 401. If another caller already
    /// refreshed past it, returns the newer token without another refresh; if a refresh is in
    /// flight, waits for it.
    public func refreshedAccessToken(replacing rejectedToken: String) async throws(GroupAPIError)
        -> String
    {
        guard let credential else { throw .notSignedIn }
        if credential.accessToken != rejectedToken, refreshTask == nil {
            return credential.accessToken
        }
        let task: Task<GroupCredential, any Error>
        if let refreshTask {
            task = refreshTask
        } else {
            let generation = generation
            task = Task { try await self.performRefresh(using: credential, generation: generation) }
            refreshTask = task
        }
        do {
            return try await task.value.accessToken
        } catch {
            throw (error as? GroupAPIError) ?? .offline
        }
    }

    private func performRefresh(using credential: GroupCredential, generation: Int)
        async throws -> GroupCredential
    {
        defer {
            if self.generation == generation { refreshTask = nil }
        }
        let response: AuthSessionResponse
        do {
            response = try await refresher(
                RefreshRequest(
                    refreshToken: credential.refreshToken, installationId: installationID))
        } catch {
            let mapped = GroupHTTPClient.mapTransportError(error)
            guard self.generation == generation else {
                if let current = self.credential { return current }
                throw GroupAPIError.notSignedIn
            }
            if mapped.rejectsSession {
                expire()
                throw GroupAPIError.notSignedIn
            }
            throw mapped
        }
        guard self.generation == generation else {
            // Signed out or in again while the refresh ran: its result is stale.
            if let current = self.credential { return current }
            throw GroupAPIError.notSignedIn
        }
        let new = GroupCredential(response)
        try? store.saveCredential(new, account: account)
        setCredential(new)
        return new
    }
}

extension GroupAPIError {
    /// A 401 on an authenticated call: refresh once and retry.
    var shouldRefreshAccessToken: Bool {
        guard case .server(let status, let error) = self else { return false }
        return status == 401 || error.code == .tokenExpired || error.code == .unauthenticated
    }

    /// A refresh answer that means the session is gone for good.
    var rejectsSession: Bool {
        guard case .server(let status, let error) = self else { return false }
        switch error.code {
        case .refreshTokenInvalid, .refreshTokenReused, .unauthenticated, .tokenExpired:
            return true
        default:
            return status == 401
        }
    }
}
