#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class GroupSessionTests: XCTestCase {
    /// spec "동시에 여러 요청이 만료를 만남": one refresh, every caller retried with the new token.
    func testConcurrentExpiredTokensShareOneRefresh() async throws {
        let refreshes = Counter()
        let transport = FakeHTTPTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                refreshes.increment()
                try await Task.sleep(for: .milliseconds(100))
                return try Fixture.json(
                    request, Fixture.session(access: "access-2", refresh: "refresh-2"))
            }
            guard request.authorization == "Bearer access-2" else {
                return try Fixture.error(request, .tokenExpired)
            }
            if request.url?.path.hasSuffix("/stickers") == true {
                return try Fixture.json(request, [String]())
            }
            return try Fixture.json(request, [Fixture.group()])
        }
        let (api, store) = Fixture.api(transport: transport)

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<6 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return try await api.groups().count
                    }
                    return try await api.stickers(groupID: UUID()).count + 1
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }

        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(refreshes.value, 1)
        let refresh = try XCTUnwrap(transport.requests(path: "/auth/refresh").first)
        XCTAssertNil(refresh.authorization)
        XCTAssertEqual(
            try PilgrimJSON.decode(RefreshRequest.self, from: try XCTUnwrap(refresh.httpBody)),
            RefreshRequest(refreshToken: "refresh-1", installationId: Fixture.installationID))
        let apiCalls = transport.requests.filter { !($0.url?.path.contains("/auth/") ?? false) }
        XCTAssertEqual(apiCalls.filter { $0.authorization == "Bearer access-2" }.count, 6)
        XCTAssertLessThanOrEqual(
            apiCalls.filter { $0.authorization == "Bearer access-1" }.count, 6)
        XCTAssertEqual(store.allCredentials[Fixture.account]?.accessToken, "access-2")
        XCTAssertEqual(store.allCredentials[Fixture.account]?.refreshToken, "refresh-2")
    }

    func testAccessTokenAboutToExpireIsRefreshedFirst() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return try Fixture.json(
                    request, Fixture.session(access: "access-2", refresh: "refresh-2"))
            }
            return try Fixture.json(request, Fixture.me())
        }
        let (api, _) = Fixture.api(
            credential: Fixture.credential(accessExpiresIn: 10), transport: transport)

        _ = try await api.me()

        XCTAssertEqual(
            transport.requests.map(\.url?.path), ["/api/v1/auth/refresh", "/api/v1/me"])
        XCTAssertEqual(transport.requests.last?.authorization, "Bearer access-2")
    }

    /// spec "refresh 재사용 감지": only the group session is cleared.
    func testRejectedRefreshClearsTheGroupSession() async throws {
        for code in [APIErrorCode.refreshTokenReused, .refreshTokenInvalid] {
            let transport = FakeHTTPTransport { request in
                if request.url?.path == "/api/v1/auth/refresh" {
                    return try Fixture.error(request, code)
                }
                return try Fixture.error(request, .tokenExpired)
            }
            let (api, store) = Fixture.api(transport: transport)
            let updates = await api.session.stateUpdates()
            var iterator = updates.makeAsyncIterator()
            let first = await iterator.next()
            XCTAssertEqual(first, .signedIn(userID: Fixture.userID))

            do {
                _ = try await api.groups()
                XCTFail("expected notSignedIn")
            } catch {
                XCTAssertEqual(error as? GroupAPIError, .notSignedIn)
                XCTAssertEqual((error as? GroupAPIError)?.requiresGroupSignIn, true)
            }

            let state = await api.session.state
            let needsSignIn = await api.session.needsSignInAgain
            XCTAssertEqual(state, .notSignedIn)
            XCTAssertTrue(needsSignIn)
            XCTAssertNil(store.allCredentials[Fixture.account])
            let next = await iterator.next()
            XCTAssertEqual(next, .notSignedIn)

            // Later calls fail locally without touching the network.
            let sent = transport.requests.count
            do {
                _ = try await api.me()
                XCTFail("expected notSignedIn")
            } catch {
                XCTAssertEqual(error as? GroupAPIError, .notSignedIn)
            }
            XCTAssertEqual(transport.requests.count, sent)
        }
    }

    func testOfflineRefreshKeepsTheSession() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                throw URLError(.notConnectedToInternet)
            }
            return try Fixture.error(request, .tokenExpired)
        }
        let (api, store) = Fixture.api(transport: transport)

        do {
            _ = try await api.groups()
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .offline)
        }
        XCTAssertEqual(store.allCredentials[Fixture.account], Fixture.credential())
        let state = await api.session.state
        XCTAssertEqual(state, .signedIn(userID: Fixture.userID))
    }

    func testSecond401AfterRefreshEndsTheSession() async throws {
        let transport = FakeHTTPTransport { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return try Fixture.json(
                    request, Fixture.session(access: "access-2", refresh: "refresh-2"))
            }
            return try Fixture.error(request, .unauthenticated)
        }
        let (api, store) = Fixture.api(transport: transport)

        do {
            _ = try await api.groups()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .notSignedIn)
        }
        XCTAssertEqual(
            transport.requests.map(\.url?.path).filter { $0 == "/api/v1/groups" }.count, 2)
        XCTAssertNil(store.allCredentials[Fixture.account])
    }

    func testNoSessionFailsWithoutARequest() async throws {
        let transport = FakeHTTPTransport { request in Fixture.empty(request) }
        let (api, _) = Fixture.api(credential: nil, transport: transport)
        do {
            _ = try await api.groups()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .notSignedIn)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testExpiredRefreshTokenEndsTheSessionLocally() async throws {
        let transport = FakeHTTPTransport { request in Fixture.empty(request) }
        let (api, store) = Fixture.api(
            credential: Fixture.credential(accessExpiresIn: -100, refreshExpiresIn: -1),
            transport: transport)
        do {
            _ = try await api.groups()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .notSignedIn)
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(store.allCredentials[Fixture.account])
    }

    func testLogOutSendsTheRefreshTokenAndClearsEvenWhenOffline() async throws {
        let transport = FakeHTTPTransport { _ in throw URLError(.notConnectedToInternet) }
        let (api, store) = Fixture.api(transport: transport)

        do {
            try await api.logOut()
            XCTFail("expected offline")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .offline)
        }

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/auth/logout")
        XCTAssertEqual(request.authorization, "Bearer access-1")
        XCTAssertEqual(
            try PilgrimJSON.decode(LogoutRequest.self, from: try XCTUnwrap(request.httpBody)),
            LogoutRequest(refreshToken: "refresh-1", installationId: Fixture.installationID))
        XCTAssertNil(store.allCredentials[Fixture.account])
        let needsSignIn = await api.session.needsSignInAgain
        XCTAssertFalse(needsSignIn)
    }

    func testDeleteAccountEndsTheSession() async throws {
        let transport = FakeHTTPTransport { request in
            try Fixture.json(
                request,
                AccountDeletionResponse(
                    deletedAt: Fixture.now, alreadyDeleted: false, groupsHandedToVote: [],
                    groupsDeleted: []))
        }
        let (api, store) = Fixture.api(transport: transport)

        _ = try await api.deleteAccount()

        XCTAssertNil(store.allCredentials[Fixture.account])
        let state = await api.session.state
        XCTAssertEqual(state, .notSignedIn)
    }

    func testSessionsAreKeyedByJournalAccount() async throws {
        let store = InMemoryGroupCredentialStore(
            credentials: ["someone-else": Fixture.credential(access: "theirs")],
            installationID: Fixture.installationID)
        let transport = FakeHTTPTransport { request in Fixture.empty(request) }
        let (api, _) = Fixture.api(store: store, transport: transport)

        let state = await api.session.state
        XCTAssertEqual(state, .notSignedIn)
    }

    func testInstallationIDIsCreatedOnceAndReused() {
        let store = InMemoryGroupCredentialStore()
        let first = store.installationIDCreatingIfNeeded()
        XCTAssertEqual(store.installationIDCreatingIfNeeded(), first)
        let api = URLSessionGroupAPI(
            configuration: Fixture.configuration, credentialStore: store,
            credentialAccount: Fixture.account,
            transport: FakeHTTPTransport { request in Fixture.empty(request) })
        XCTAssertEqual(api.installationID, first)
    }

    func testCredentialJSONMatchesTheKeychainContract() throws {
        let credential = Fixture.credential()
        let data = try credential.encoded()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "accessToken", "accessTokenExpiresAt", "refreshToken", "refreshTokenExpiresAt",
                "userId",
            ])
        XCTAssertEqual(object["userId"] as? String, Fixture.userID.uuidString.lowercased())
        XCTAssertEqual(try GroupCredential.decoded(from: data), credential)
        XCTAssertEqual(GroupCredential.keychainService, "com.dhouse.PilgrimJournal.group-session")
    }

    func testFailingKeychainKeepsTheSessionInMemory() async throws {
        let store = InMemoryGroupCredentialStore(installationID: Fixture.installationID)
        store.failSaves(with: CocoaError(.fileWriteUnknown))
        let transport = FakeHTTPTransport { request in
            if request.url?.path == "/api/v1/auth/dev" {
                return try Fixture.json(request, Fixture.session(access: "a", refresh: "r"))
            }
            return try Fixture.json(request, Fixture.me())
        }
        let (api, _) = Fixture.api(credential: nil, store: store, transport: transport)

        try await api.signInForDevelopment(devUser: "tester")
        _ = try await api.me()

        XCTAssertEqual(transport.requests.last?.authorization, "Bearer a")
        XCTAssertTrue(store.allCredentials.isEmpty)
    }
}
#endif
