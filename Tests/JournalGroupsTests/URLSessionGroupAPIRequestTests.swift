#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class URLSessionGroupAPIRequestTests: XCTestCase {
    func testAuthenticatedRequestCarriesClientHeaderAndBearerToken() async throws {
        let transport = FakeHTTPTransport { request in
            try Fixture.json(request, [Fixture.group()])
        }
        let (api, _) = Fixture.api(transport: transport)

        let groups = try await api.groups()

        XCTAssertEqual(groups.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString, "https://pilgrim.delight-house.org/api/v1/groups")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Pilgrim-Client"),
            "ios/1.3.0 (31) com.dhouse.PilgrimJournal")
        XCTAssertEqual(request.authorization, "Bearer access-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
        XCTAssertNotNil(ClientHeader(request.value(forHTTPHeaderField: ClientHeader.name)!))
    }

    func testPagingQueryIsEscapedAndPathUsesLowercaseIDs() async throws {
        let groupID = UUID()
        let transport = FakeHTTPTransport { request in
            try Fixture.json(request, Page<PostResponse>(items: [], nextCursor: nil))
        }
        let (api, _) = Fixture.api(transport: transport)

        _ = try await api.posts(groupID: groupID, cursor: "a+b/c=", limit: 20)

        let url = try XCTUnwrap(transport.requests.first?.url)
        XCTAssertEqual(url.path, "/api/v1/groups/\(groupID.uuidString.lowercased())/posts")
        XCTAssertEqual(url.query, "cursor=a%2Bb%2Fc%3D&limit=20")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first?.value, "a+b/c=")
    }

    func testJSONBodyIsPilgrimJSON() async throws {
        let groupID = UUID()
        let clientID = UUID()
        let transport = FakeHTTPTransport { request in
            try Fixture.json(
                request, Fixture.post(groupID: groupID, createdAt: Fixture.now), status: 201)
        }
        let (api, _) = Fixture.api(transport: transport)
        let body = CreatePostRequest(
            clientId: clientID, kind: .prayer, items: [PrayerItem(text: "건강")],
            deadline: LocalDate("2026-11-20"), timeZone: "Asia/Seoul")

        _ = try await api.createPost(groupID: groupID, body)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(
            try PilgrimJSON.decode(CreatePostRequest.self, from: try XCTUnwrap(request.httpBody)),
            body)
        XCTAssertTrue(request.bodyString.contains(clientID.uuidString.lowercased()))
        XCTAssertTrue(request.bodyString.contains("\"deadline\":\"2026-11-20\""))
    }

    func testSignInWithAppleSendsNoTokenAndStoresTheSession() async throws {
        let transport = FakeHTTPTransport { request in
            try Fixture.json(request, Fixture.session(access: "new-access", refresh: "new-refresh"))
        }
        let (api, store) = Fixture.api(credential: nil, transport: transport)
        let nonce = AppleSignInNonce(raw: "raw-nonce")

        try await api.signInWithApple(
            identityToken: "id-token", authorizationCode: "code", rawNonce: nonce.raw)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/auth/apple")
        XCTAssertNil(request.authorization)
        let sent = try PilgrimJSON.decode(
            AppleSignInRequest.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            sent,
            AppleSignInRequest(
                identityToken: "id-token", authorizationCode: "code", rawNonce: "raw-nonce",
                bundleId: BundleIDs.release, installationId: Fixture.installationID))
        let state = await api.session.state
        XCTAssertEqual(state, .signedIn(userID: Fixture.userID))
        XCTAssertEqual(store.allCredentials[Fixture.account]?.accessToken, "new-access")
    }

    func testDevelopmentSignInAgainstLocalServer() async throws {
        let transport = FakeHTTPTransport { request in
            try Fixture.json(request, Fixture.session(access: "dev-access", refresh: "dev-refresh"))
        }
        let configuration = try XCTUnwrap(
            GroupServerConfiguration(
                serverURLString: "http://localhost:3100/api/v1/", client: Fixture.client))
        let (api, _) = Fixture.api(
            credential: nil, configuration: configuration, transport: transport)

        try await api.signInForDevelopment(devUser: "tester")
        _ = try? await api.me()

        XCTAssertEqual(
            transport.requests.map(\.url?.absoluteString),
            ["http://localhost:3100/api/v1/auth/dev", "http://localhost:3100/api/v1/me"])
        XCTAssertEqual(transport.requests.last?.authorization, "Bearer dev-access")
        let sent = try PilgrimJSON.decode(
            DevSignInRequest.self, from: try XCTUnwrap(transport.requests.first?.httpBody))
        XCTAssertEqual(sent.devUser, "tester")
        XCTAssertEqual(sent.installationId, Fixture.installationID)
    }

    func testReactionRemovalUsesQueryAndInviteCodesAreNormalized() async throws {
        let postID = UUID()
        let transport = FakeHTTPTransport { request in
            if request.url?.path.hasSuffix("accept") == true {
                throw URLError(.notConnectedToInternet)
            }
            return try Fixture.json(request, [ReactionSummary]())
        }
        let (api, _) = Fixture.api(transport: transport)

        _ = try await api.removeReaction(postID: postID, key: .emoji("🙏"))
        _ = try? await api.acceptInvite(code: "prev-1ew0-c0de")

        let reaction = transport.requests[0]
        XCTAssertEqual(reaction.httpMethod, "DELETE")
        XCTAssertEqual(reaction.url?.query, "emoji=%F0%9F%99%8F")
        let accept = transport.requests[1]
        XCTAssertEqual(accept.url?.path, "/api/v1/invites/PREV1EW0C0DE/accept")
        XCTAssertEqual(accept.bodyString, "{}")
    }

    /// Every endpoint's method and path (design.md "API"). The fake answers 204, so calls that
    /// decode a body fail; only the request matters here.
    func testEveryEndpointMethodAndPath() async throws {
        let transport = FakeHTTPTransport { request in Fixture.empty(request) }
        let (api, _) = Fixture.api(transport: transport)
        let id = UUID()
        let other = UUID()
        let i = id.uuidString.lowercased()
        let o = other.uuidString.lowercased()
        let code = "PREV1EW0C0DE"

        let calls: [(String, String, () async throws -> Void)] = [
            ("GET", "/me", { _ = try await api.me() }),
            ("PATCH", "/me", { _ = try await api.updateMe(UpdateMeRequest(displayName: "민지")) }),
            ("DELETE", "/me", { _ = try await api.deleteAccount() }),
            (
                "PUT", "/me/devices/\(i)",
                {
                    try await api.registerDevice(
                        installationID: id,
                        DeviceRegistrationRequest(
                            apnsToken: nil, apnsEnvironment: .sandbox, bundleId: BundleIDs.debug,
                            platform: .ios, locale: "ko-KR", timeZone: "Asia/Seoul",
                            appVersion: "1.3.0"))
                }
            ),
            ("DELETE", "/me/devices/\(i)", { try await api.unregisterDevice(installationID: id) }),
            ("GET", "/me/daily-report", { _ = try await api.dailyReport(date: nil) }),
            ("GET", "/me/entitlement", { _ = try await api.entitlement() }),
            ("GET", "/me/blocks", { _ = try await api.blockedUsers() }),
            ("PUT", "/me/blocks/\(i)", { try await api.block(userID: id) }),
            ("DELETE", "/me/blocks/\(i)", { try await api.unblock(userID: id) }),
            ("GET", "/me/hides", { _ = try await api.hides() }),
            ("PUT", "/me/hides/posts/\(i)", { try await api.hidePost(id: id) }),
            ("DELETE", "/me/hides/posts/\(i)", { try await api.unhidePost(id: id) }),
            ("PUT", "/me/hides/users/\(i)", { try await api.hideUser(id: id) }),
            ("DELETE", "/me/hides/users/\(i)", { try await api.unhideUser(id: id) }),
            (
                "POST", "/subscriptions/verify",
                {
                    _ = try await api.verifySubscription(
                        VerifySubscriptionRequest(signedTransaction: "jws", bundleId: "b"))
                }
            ),
            (
                "POST", "/uploads",
                {
                    _ = try await api.upload(
                        GroupMediaUpload(
                            clientID: id, purpose: .post, groupID: other, jpegData: Data([1]),
                            width: 1, height: 1))
                }
            ),
            ("GET", "/media/\(i)", { _ = try await api.mediaURL(id: id) }),
            ("GET", "/groups", { _ = try await api.groups() }),
            (
                "POST", "/groups",
                { _ = try await api.createGroup(CreateGroupRequest(clientId: id, name: "모임")) }
            ),
            ("GET", "/groups/\(i)", { _ = try await api.group(id: id) }),
            (
                "PATCH", "/groups/\(i)",
                { _ = try await api.updateGroup(id: id, UpdateGroupRequest(name: "모임")) }
            ),
            ("DELETE", "/groups/\(i)", { try await api.deleteGroup(id: id) }),
            ("POST", "/groups/\(i)/leave", { try await api.leaveGroup(id: id) }),
            (
                "GET", "/groups/\(i)/members",
                { _ = try await api.members(groupID: id, cursor: nil, limit: nil) }
            ),
            (
                "DELETE", "/groups/\(i)/members/\(o)",
                { try await api.removeMember(groupID: id, userID: other) }
            ),
            ("GET", "/groups/\(i)/bans", { _ = try await api.bans(groupID: id) }),
            (
                "DELETE", "/groups/\(i)/bans/\(o)",
                { try await api.unban(groupID: id, userID: other) }
            ),
            (
                "POST", "/groups/\(i)/admin/transfer",
                {
                    _ = try await api.transferAdmin(
                        groupID: id, TransferAdminRequest(userId: other))
                }
            ),
            ("POST", "/groups/\(i)/seen", { try await api.markSeen(groupID: id) }),
            (
                "PUT", "/groups/\(i)/notifications",
                {
                    try await api.updateNotifications(
                        groupID: id, GroupNotificationSettings())
                }
            ),
            ("GET", "/groups/\(i)/vote", { _ = try await api.vote(groupID: id) }),
            (
                "POST", "/groups/\(i)/vote/ballot",
                {
                    _ = try await api.castBallot(
                        groupID: id, CastBallotRequest(candidateUserId: other))
                }
            ),
            (
                "POST", "/groups/\(i)/invites",
                {
                    _ = try await api.createInvite(
                        groupID: id, CreateInviteRequest(clientId: other, maxUses: 5))
                }
            ),
            ("GET", "/groups/\(i)/invites", { _ = try await api.invites(groupID: id) }),
            (
                "DELETE", "/groups/\(i)/invites/\(code)",
                { try await api.revokeInvite(groupID: id, code: code) }
            ),
            ("GET", "/invites/\(code)", { _ = try await api.invitePreview(code: code) }),
            ("POST", "/invites/\(code)/accept", { _ = try await api.acceptInvite(code: code) }),
            (
                "GET", "/groups/\(i)/posts",
                { _ = try await api.posts(groupID: id, cursor: nil, limit: nil) }
            ),
            (
                "POST", "/groups/\(i)/posts",
                {
                    _ = try await api.createPost(
                        groupID: id,
                        CreatePostRequest(
                            clientId: other, kind: .testimony, body: "본문",
                            timeZone: "Asia/Seoul"))
                }
            ),
            ("GET", "/posts/\(i)", { _ = try await api.post(id: id) }),
            ("DELETE", "/posts/\(i)", { try await api.deletePost(id: id) }),
            (
                "POST", "/posts/\(i)/extend",
                { _ = try await api.extendPost(id: id, ExtendPostRequest(clientId: other)) }
            ),
            (
                "GET", "/posts/\(i)/comments",
                { _ = try await api.comments(postID: id, cursor: nil, limit: nil) }
            ),
            (
                "POST", "/posts/\(i)/comments",
                {
                    _ = try await api.createComment(
                        postID: id, CreateCommentRequest(clientId: other, body: "아멘"))
                }
            ),
            ("DELETE", "/comments/\(i)", { try await api.deleteComment(id: id) }),
            (
                "PUT", "/posts/\(i)/reactions",
                { _ = try await api.react(postID: id, ReactionRequest(key: .sticker(other))) }
            ),
            (
                "DELETE", "/posts/\(i)/reactions",
                { _ = try await api.removeReaction(postID: id, key: .sticker(other)) }
            ),
            ("GET", "/groups/\(i)/stickers", { _ = try await api.stickers(groupID: id) }),
            (
                "POST", "/groups/\(i)/stickers",
                {
                    _ = try await api.createSticker(
                        groupID: id, CreateStickerRequest(clientId: other, mediaId: id))
                }
            ),
            ("DELETE", "/stickers/\(i)", { try await api.deleteSticker(id: id) }),
            (
                "POST", "/reports",
                {
                    _ = try await api.report(
                        CreateReportRequest(
                            clientId: other, targetType: .post, targetId: id, groupId: other,
                            reason: .spam))
                }
            ),
        ]

        for (index, (method, path, call)) in calls.enumerated() {
            // Account deletion signs out; keep a session for every call.
            if index > 0, await api.session.isSignedIn == false {
                await api.session.start(Fixture.session(access: "access-1", refresh: "r"))
            }
            try? await call()
            let request = try XCTUnwrap(transport.requests.last, path)
            XCTAssertEqual(request.httpMethod, method, path)
            XCTAssertEqual(request.url?.path, "/api/v1" + path, path)
            XCTAssertEqual(request.authorization, "Bearer access-1", path)
            XCTAssertNotNil(request.value(forHTTPHeaderField: ClientHeader.name), path)
        }
        XCTAssertEqual(transport.requests.count, calls.count)
    }

    func testDailyReportDateQuery() async throws {
        let transport = FakeHTTPTransport { request in Fixture.empty(request) }
        let (api, _) = Fixture.api(transport: transport)

        _ = try? await api.dailyReport(date: LocalDate("2026-11-20"))

        XCTAssertEqual(transport.requests.first?.url?.query, "date=2026-11-20")
    }

    func testConfigurationNormalizesServerURL() throws {
        let variants = [
            "https://pilgrim.delight-house.org", "https://pilgrim.delight-house.org/",
            "https://pilgrim.delight-house.org/api/v1",
            " https://pilgrim.delight-house.org/api/v1/ ",
        ]
        for variant in variants {
            let configuration = try XCTUnwrap(
                GroupServerConfiguration(serverURLString: variant, client: Fixture.client),
                variant)
            XCTAssertEqual(
                configuration.apiBaseURL.absoluteString,
                "https://pilgrim.delight-house.org/api/v1", variant)
        }
        XCTAssertNil(GroupServerConfiguration(serverURLString: "", client: Fixture.client))
        XCTAssertNil(
            GroupServerConfiguration(serverURLString: "ftp://example.com", client: Fixture.client))
        XCTAssertEqual(
            GroupServerConfiguration.localDevelopment(client: Fixture.client).apiBaseURL
                .absoluteString,
            "http://localhost:3100/api/v1")
    }
}
#endif
