#if canImport(XCTest)
import Foundation
import JournalData
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

@MainActor
final class GroupAccountErasureTests: XCTestCase {
    private let journalUser = GroupsMembershipFixtures.journalUser
    private var account: String { GroupCredentialStore.account(forAppleUser: journalUser) }
    private var marker: String { GroupAccountErasure.pendingDeletionAccount(for: account) }
    private let installationID = GroupCredentialStore.installationIDAccount

    // MARK: No-op cases

    func testDisabledGroupsIsANoOpSuccess() async throws {
        let client = FakeGroupDeletionClient(hasSession: true)
        let keychain = keychainWithSession()
        var builtClients = 0
        let erasure = GroupAccountErasure(
            isEnabled: false, keychain: keychain,
            authorizer: FakeGroupAppleAuthorizer(user: journalUser), developmentAppleUser: nil
        ) { _ in
            builtClients += 1
            return client
        }

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        XCTAssertEqual(builtClients, 0)
        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(keychain.accounts, [account, installationID])
    }

    func testNeverSignedInIsANoOpSuccess() async throws {
        let client = FakeGroupDeletionClient(hasSession: false)
        let authorizer = FakeGroupAppleAuthorizer(user: journalUser)
        let erasure = makeErasure(client: client, authorizer: authorizer)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession"], "서버에 요청하면 안 됩니다.")
        XCTAssertTrue(authorizer.hashedNonces.isEmpty)
    }

    // MARK: Deletion

    func testDeletesTheAccountAndClearsTheGroupKeychain() async throws {
        let client = FakeGroupDeletionClient(hasSession: true)
        let keychain = keychainWithSession()
        var requestedAccounts: [String] = []
        let erasure = GroupAccountErasure(
            isEnabled: true, keychain: keychain,
            authorizer: FakeGroupAppleAuthorizer(user: journalUser), developmentAppleUser: nil
        ) { account in
            requestedAccounts.append(account)
            return client
        }

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        XCTAssertEqual(requestedAccounts, [account])
        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession", "delete"])
        XCTAssertTrue(keychain.accounts.isEmpty, "그룹 Keychain 항목이 모두 지워져야 합니다.")
    }

    func testKeepsAnotherJournalUsersSessionAndTheInstallationID() async throws {
        let keychain = keychainWithSession()
        keychain.save(Data("theirs".utf8), for: "other-user-hash")
        let erasure = makeErasure(
            client: FakeGroupDeletionClient(hasSession: true), keychain: keychain)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        XCTAssertEqual(keychain.accounts, ["other-user-hash", installationID])
    }

    func testAlreadyDeletedAccountCountsAsSuccess() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true,
            deleteResults: [.success(AccountDeletionResponse(deletedAt: nil, alreadyDeleted: true))]
        )
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: client, keychain: keychain)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    func testRunningTwiceAfterSuccessDoesNothingTheSecondTime() async throws {
        let client = FakeGroupDeletionClient(hasSession: true)
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: client, keychain: keychain)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)
        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        // The fake's session ends with the delete, as `URLSessionGroupAPI`'s does.
        XCTAssertEqual(calls, ["hasSession", "delete", "hasSession"])
    }

    // MARK: Failures stop the deletion

    func testOfflineFailureThrowsAndKeepsThePendingMarker() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.offline)])
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: client, keychain: keychain)

        do {
            try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)
            XCTFail("연결이 없으면 실패해야 합니다.")
        } catch {
            XCTAssertEqual(error as? GroupAccountErasureError, .server(.offline))
            XCTAssertEqual(error.localizedDescription, GroupMessages.offline)
        }

        XCTAssertTrue(keychain.accounts.contains(marker))
        XCTAssertTrue(keychain.accounts.contains(account))
    }

    // MARK: Rejected session → Apple re-authentication

    func testRejectedSessionReauthenticatesWithAppleThenDeletes() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.notSignedIn)])
        let authorizer = FakeGroupAppleAuthorizer(user: journalUser)
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: client, authorizer: authorizer, keychain: keychain)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession", "delete", "apple:identity-token", "delete"])
        XCTAssertEqual(authorizer.hashedNonces.count, 1)
        let rawNonces = await client.rawNonces
        let rawNonce = try XCTUnwrap(rawNonces.first)
        XCTAssertEqual(GroupAppleNonce(raw: rawNonce).hashed, authorizer.hashedNonces.first)
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    func testRefreshTokenInvalidAlsoReauthenticates() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.server(.refreshTokenInvalid))])
        let erasure = makeErasure(client: client)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession", "delete", "apple:identity-token", "delete"])
    }

    func testDifferentAppleUserIsRefusedBeforeSigningIn() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.notSignedIn)])
        let erasure = makeErasure(
            client: client, authorizer: FakeGroupAppleAuthorizer(user: "someone-else"))

        do {
            try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)
            XCTFail("다른 Apple 사용자면 실패해야 합니다.")
        } catch {
            XCTAssertEqual(
                error as? GroupAccountErasureError, .appleAuthorization(.differentUser))
        }
        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession", "delete"], "서버에 로그인하면 안 됩니다.")
    }

    func testRetryAfterCancelledReauthenticationStillDeletes() async throws {
        // The rejected refresh already removed the session from the Keychain, so only the
        // pending marker says the server account is still there.
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.notSignedIn)], endsSessionOnFailure: true)
        let authorizer = FakeGroupAppleAuthorizer(
            user: journalUser, failure: GroupAppleAuthorizationError.cancelled)
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: client, authorizer: authorizer, keychain: keychain)

        do {
            try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)
            XCTFail("Apple 인증을 취소하면 실패해야 합니다.")
        } catch {
            XCTAssertEqual(error as? GroupAccountErasureError, .appleAuthorization(.cancelled))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertTrue(keychain.accounts.contains(marker))

        authorizer.failure = nil
        await client.setDeleteResults([.failure(.notSignedIn)])
        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        XCTAssertEqual(
            calls,
            [
                "hasSession", "delete", "hasSession", "delete", "apple:identity-token",
                "delete",
            ])
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    func testDevelopmentSignInReplacesAppleInDebug() async throws {
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.notSignedIn)])
        let authorizer = FakeGroupAppleAuthorizer(user: journalUser)
        let erasure = GroupAccountErasure(
            isEnabled: true, keychain: keychainWithSession(), authorizer: authorizer,
            developmentAppleUser: "dev-minji"
        ) { _ in client }

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        let calls = await client.calls
        XCTAssertEqual(calls, ["hasSession", "delete", "dev:dev-minji", "delete"])
        XCTAssertTrue(authorizer.hashedNonces.isEmpty)
    }

    // MARK: With the real client

    func testLiveClientReauthenticatesAfterRefreshTokenInvalid() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = InMemoryGroupCredentialStore(
            credentials: [
                account: GroupCredential(
                    accessToken: "stale", accessTokenExpiresAt: now - 60, refreshToken: "dead",
                    refreshTokenExpiresAt: now + 86_400, userId: UUID())
            ],
            installationID: UUID())
        let transport = ScriptedTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/auth/refresh"):
                return try ScriptedTransport.error(request, .refreshTokenInvalid)
            case ("POST", "/api/v1/auth/apple"):
                return try ScriptedTransport.json(
                    request, GroupAccountErasureFixtures.session(now: now, access: "fresh"))
            case ("DELETE", "/api/v1/me"):
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                else { return try ScriptedTransport.error(request, .unauthenticated) }
                return try ScriptedTransport.json(
                    request,
                    AccountDeletionResponse(
                        deletedAt: now, alreadyDeleted: false, groupsHandedToVote: [UUID()]))
            default:
                return try ScriptedTransport.error(request, .notFound)
            }
        }
        let client = ClientHeader(
            platform: .ios, version: ClientVersion("1.3.0")!, build: "31",
            bundleID: BundleIDs.debug)
        let api = URLSessionGroupAPI(
            configuration: .production(client: client), credentialStore: store,
            credentialAccount: account, transport: transport, now: { now })
        let keychain = keychainWithSession()
        let erasure = makeErasure(client: api, keychain: keychain)

        try await erasure.eraseRemoteData(appleUserIdentifier: journalUser)

        XCTAssertEqual(
            transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            ["POST /api/v1/auth/refresh", "POST /api/v1/auth/apple", "DELETE /api/v1/me"])
        XCTAssertTrue(store.allCredentials.isEmpty)
        let signedIn = await api.hasGroupSession()
        XCTAssertFalse(signedIn)
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    // MARK: Through account deletion and the coordinator

    func testGroupServerFailureLeavesTheJournalAndOffersRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "GroupAccountErasure-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = JournalAccountScope(
            appleUserIdentifier: journalUser, storageLocation: .localOnly)
        let paths = try JournalAccountScopeRegistry(root: root).prepareScope(scope)
        let sessionService = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        let client = FakeGroupDeletionClient(
            hasSession: true, deleteResults: [.failure(.offline)])
        let keychain = keychainWithSession()
        let coordinator = AppleAuthenticationCoordinator(
            service: sessionService,
            credentialChecker: AlwaysAuthorizedChecker(),
            accountDeleter: AccountDeletionService(
                rootURLProvider: { root }, cloudEraser: nil,
                remoteEraser: makeErasure(client: client, keychain: keychain),
                sessionService: sessionService, appLockStore: InMemorySecureValueStore(),
                preferences: IgnoringPreferences())
        )
        await coordinator.acceptAuthorizedUser(identifier: journalUser)

        let first = await coordinator.deleteAccount(storageLocation: .localOnly) {}

        XCTAssertFalse(first)
        guard case let .failed(message, canReturnToJournal) = coordinator.accountDeletionPhase
        else { return XCTFail("실패 상태여야 합니다.") }
        XCTAssertTrue(canReturnToJournal)
        XCTAssertTrue(message.contains("그룹 서버 계정을 지우지 못했어요"))
        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.root.path(percentEncoded: false)))

        coordinator.dismissAccountDeletionFailure()
        let second = await coordinator.deleteAccount(storageLocation: .localOnly) {}

        XCTAssertTrue(second)
        XCTAssertTrue(coordinator.didCompleteAccountDeletion)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.root.path(percentEncoded: false)))
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    // MARK: Confirmation notice

    func testNoticeCountsGroupsIRunThatAreNotAlreadyBeingDeleted() {
        let me = GroupAccountErasureFixtures.me(status: .none)
        let groups = [
            GroupAccountErasureFixtures.group(isAdmin: true, status: .active),
            GroupAccountErasureFixtures.group(isAdmin: true, status: .active),
            GroupAccountErasureFixtures.group(isAdmin: true, status: .pendingDeletion),
            GroupAccountErasureFixtures.group(isAdmin: false, status: .active),
            GroupAccountErasureFixtures.group(isAdmin: false, status: .voting),
        ]

        let notice = GroupAccountDeletionNotice(me: me, groups: groups)

        XCTAssertTrue(notice.hasGroupAccount)
        XCTAssertEqual(notice.adminGroupCount, 2)
        XCTAssertFalse(notice.hasAppStoreSubscription)
    }

    func testNoticeAsksToCancelAnActiveSubscription() {
        for status in [SubscriptionStatus.active, .gracePeriod, .billingRetry] {
            let notice = GroupAccountDeletionNotice(
                me: GroupAccountErasureFixtures.me(status: status), groups: [])
            XCTAssertTrue(notice.hasAppStoreSubscription, "\(status)")
        }
        for status in [SubscriptionStatus.expired, .revoked, .none] {
            let notice = GroupAccountDeletionNotice(
                me: GroupAccountErasureFixtures.me(status: status), groups: [])
            XCTAssertFalse(notice.hasAppStoreSubscription, "\(status)")
        }
    }

    func testNoticeIsEmptyWithoutAGroupProfile() {
        let notice = GroupAccountDeletionNotice(
            me: nil, groups: [GroupAccountErasureFixtures.group(isAdmin: true, status: .active)])

        XCTAssertFalse(notice.hasGroupAccount)
        XCTAssertEqual(notice.adminGroupCount, 0)
        XCTAssertFalse(notice.hasAppStoreSubscription)
    }

    // MARK: Helpers

    private func keychainWithSession() -> InMemoryGroupSecureItemStore {
        let keychain = InMemoryGroupSecureItemStore()
        keychain.save(Data("session".utf8), for: account)
        keychain.save(Data(UUID().uuidString.utf8), for: installationID)
        return keychain
    }

    private func makeErasure(
        client: any GroupAccountDeletionClient,
        authorizer: FakeGroupAppleAuthorizer? = nil,
        keychain: InMemoryGroupSecureItemStore? = nil
    ) -> GroupAccountErasure {
        GroupAccountErasure(
            isEnabled: true, keychain: keychain ?? keychainWithSession(),
            authorizer: authorizer ?? FakeGroupAppleAuthorizer(user: journalUser),
            developmentAppleUser: nil
        ) { _ in client }
    }
}

/// A group server for account deletion: `deleteResults` answer `DELETE /me` in turn (then
/// success), a sign-in starts a session, a successful delete ends it.
private actor FakeGroupDeletionClient: GroupAccountDeletionClient {
    private var hasSession: Bool
    private var deleteResults: [Result<AccountDeletionResponse, GroupAPIError>]
    /// A rejected session is dropped as `GroupSession` drops it.
    private let endsSessionOnFailure: Bool
    private(set) var calls: [String] = []
    private(set) var rawNonces: [String] = []

    init(
        hasSession: Bool, deleteResults: [Result<AccountDeletionResponse, GroupAPIError>] = [],
        endsSessionOnFailure: Bool = false
    ) {
        self.hasSession = hasSession
        self.deleteResults = deleteResults
        self.endsSessionOnFailure = endsSessionOnFailure
    }

    func setDeleteResults(_ results: [Result<AccountDeletionResponse, GroupAPIError>]) {
        deleteResults = results
    }

    func hasGroupSession() -> Bool {
        calls.append("hasSession")
        return hasSession
    }

    func deleteAccount() throws -> AccountDeletionResponse {
        calls.append("delete")
        let result =
            deleteResults.isEmpty
            ? .success(AccountDeletionResponse(deletedAt: Date(), alreadyDeleted: false))
            : deleteResults.removeFirst()
        switch result {
        case .success(let response):
            hasSession = false
            return response
        case .failure(let error):
            if endsSessionOnFailure, error.requiresGroupSignIn { hasSession = false }
            throw error
        }
    }

    func signInWithApple(identityToken: String, authorizationCode: String, rawNonce: String)
        -> AuthSessionResponse
    {
        calls.append("apple:\(identityToken)")
        rawNonces.append(rawNonce)
        hasSession = true
        return GroupAccountErasureFixtures.session(now: Date(), access: "fresh")
    }

    func signInForDevelopment(devUser: String) -> AuthSessionResponse {
        calls.append("dev:\(devUser)")
        hasSession = true
        return GroupAccountErasureFixtures.session(now: Date(), access: "fresh")
    }
}

private enum GroupAccountErasureFixtures {
    static func me(status: SubscriptionStatus) -> MeResponse {
        MeResponse(
            id: UUID(), displayName: "민지", profileComplete: true, timeZone: "Asia/Seoul",
            dailyReportEnabled: true, dailyReportTime: .defaultDailyReport, createdAt: Date(),
            entitlement: EntitlementResponse(
                subscriptionRequired: false, active: true, status: status))
    }

    static func session(now: Date, access: String) -> AuthSessionResponse {
        AuthSessionResponse(
            accessToken: access, accessTokenExpiresAt: now + SessionLifetime.accessToken,
            refreshToken: "refresh-\(access)",
            refreshTokenExpiresAt: now + SessionLifetime.refreshToken, user: me(status: .none))
    }

    static func group(isAdmin: Bool, status: GroupStatus) -> GroupSummary {
        GroupSummary(
            id: UUID(), name: "수요 기도모임", status: status, memberCount: 3, isAdmin: isAdmin,
            admin: nil, unreadCount: 0, latestPostAt: nil,
            notifications: GroupNotificationSettings())
    }
}

/// A scripted `HTTPTransport` that records every request.
private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }

    static func json(_ request: URLRequest, _ value: some Encodable) throws
        -> (Data, HTTPURLResponse)
    {
        (try PilgrimJSON.encode(value), response(request, status: 200))
    }

    static func error(_ request: URLRequest, _ code: APIErrorCode) throws
        -> (Data, HTTPURLResponse)
    {
        let body = APIErrorBody(error: APIError(code: code, message: code.rawValue))
        return (try PilgrimJSON.encode(body), response(request, status: code.httpStatus))
    }

    private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
    }
}

@MainActor
private struct AlwaysAuthorizedChecker: AppleCredentialStateChecking {
    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        .authorized
    }
}

private struct IgnoringPreferences: AccountPreferencesClearing {
    func removeSuite(named suiteName: String) {}
    func removeStandardValues(forKeys keys: [String]) {}
    func removeCloudValues(forKeys keys: [String]) {}
}
#endif
