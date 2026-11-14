import Foundation
import PilgrimAPI

/// The real group-server client: `GroupAPI` over an `HTTPTransport` (URLSession in the app).
///
/// Every request carries `X-Pilgrim-Client`; authenticated ones carry the session's access
/// token. A 401 refreshes the session once (shared with any concurrent caller, see
/// `GroupSession`) and retries the request once; a second 401 ends the group session
/// (`GroupAPIError.notSignedIn`). Errors are always `GroupAPIError`: an error body becomes
/// `.server(status:error:)` (426 → `CLIENT_UPGRADE_REQUIRED`), no connection `.offline`, a
/// timeout `.timedOut`, a cancelled task `.cancelled`.
public final class URLSessionGroupAPI: GroupAPI {
    public let configuration: GroupServerConfiguration
    /// The group session; observe `stateUpdates()` for sign-in state.
    public let session: GroupSession
    let http: GroupHTTPClient

    /// - Parameters:
    ///   - credentialStore: the Keychain adapter (or `InMemoryGroupCredentialStore`).
    ///   - credentialAccount: the journal session's Apple user hash.
    ///   - installationID: nil reads (or creates) the store's installation ID.
    public init(
        configuration: GroupServerConfiguration, credentialStore: any GroupCredentialStoring,
        credentialAccount: String, installationID: UUID? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let http = GroupHTTPClient(configuration: configuration, transport: transport)
        self.configuration = configuration
        self.http = http
        self.session = GroupSession(
            account: credentialAccount,
            installationID: installationID ?? credentialStore.installationIDCreatingIfNeeded(),
            store: credentialStore, now: now,
            refresher: { request in
                try await http.send(
                    .json(.post, ["auth", "refresh"], request, requiresAuthentication: false),
                    accessToken: nil, as: AuthSessionResponse.self)
            })
    }

    public var installationID: UUID { session.installationID }
    public var bundleID: String { configuration.bundleID }

    // MARK: Plumbing

    /// Sends with the session's token, refreshing and retrying once on 401.
    func data(_ endpoint: GroupEndpoint) async throws(GroupAPIError) -> Data {
        guard endpoint.requiresAuthentication else {
            return try await http.data(endpoint, accessToken: nil)
        }
        let token = try await session.validAccessToken()
        do {
            return try await http.data(endpoint, accessToken: token)
        } catch {
            guard error.shouldRefreshAccessToken else { throw error }
        }
        let fresh = try await session.refreshedAccessToken(replacing: token)
        do {
            return try await http.data(endpoint, accessToken: fresh)
        } catch {
            guard error.shouldRefreshAccessToken else { throw error }
            await session.expire()
            throw .notSignedIn
        }
    }

    func send<Response: Decodable>(_ endpoint: GroupEndpoint, as type: Response.Type)
        async throws(GroupAPIError) -> Response
    {
        try GroupHTTPClient.decode(type, from: try await data(endpoint))
    }

    func send(_ endpoint: GroupEndpoint) async throws(GroupAPIError) {
        _ = try await data(endpoint)
    }

    private static func pageQuery(cursor: String?, limit: Int?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return items
    }

    /// Invite codes go into paths normalized when they parse; anything else is sent as typed
    /// (escaped) so the server answers `NOT_FOUND` the same way it does for a wrong code.
    private static func inviteSegment(_ code: String) -> String {
        InviteCode(normalizing: code)?.rawValue ?? code
    }

    // MARK: Auth

    public func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthSessionResponse {
        let response = try await send(
            .json(.post, ["auth", "apple"], request, requiresAuthentication: false),
            as: AuthSessionResponse.self)
        await session.start(response)
        return response
    }

    public func signInForDevelopment(_ request: DevSignInRequest) async throws
        -> AuthSessionResponse
    {
        let response = try await send(
            .json(.post, ["auth", "dev"], request, requiresAuthentication: false),
            as: AuthSessionResponse.self)
        await session.start(response)
        return response
    }

    public func refreshSession(_ request: RefreshRequest) async throws -> AuthSessionResponse {
        let response = try await send(
            .json(.post, ["auth", "refresh"], request, requiresAuthentication: false),
            as: AuthSessionResponse.self)
        await session.start(response)
        return response
    }

    /// Clears the local group session whatever the server answers (an offline logout still
    /// signs this device out; the server family then simply expires).
    public func logOut(_ request: LogoutRequest) async throws {
        do {
            try await send(.json(.post, ["auth", "logout"], request))
        } catch {
            await session.signOut()
            throw error
        }
        await session.signOut()
    }

    // MARK: Me

    public func me() async throws -> MeResponse {
        try await send(GroupEndpoint(.get, ["me"]), as: MeResponse.self)
    }

    public func updateMe(_ request: UpdateMeRequest) async throws -> MeResponse {
        try await send(.json(.patch, ["me"], request), as: MeResponse.self)
    }

    /// Ends the group session after the server confirms (including `alreadyDeleted`).
    public func deleteAccount() async throws -> AccountDeletionResponse {
        let response = try await send(
            GroupEndpoint(.delete, ["me"]), as: AccountDeletionResponse.self)
        await session.signOut()
        return response
    }

    public func registerDevice(installationID: UUID, _ request: DeviceRegistrationRequest)
        async throws
    {
        try await send(.json(.put, ["me", "devices", installationID.pilgrimString], request))
    }

    public func unregisterDevice(installationID: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["me", "devices", installationID.pilgrimString]))
    }

    public func dailyReport(date: LocalDate?) async throws -> DailyReportResponse {
        let query = date.map { [URLQueryItem(name: "date", value: $0.description)] } ?? []
        return try await send(
            GroupEndpoint(.get, ["me", "daily-report"], query: query),
            as: DailyReportResponse.self)
    }

    public func entitlement() async throws -> EntitlementResponse {
        try await send(GroupEndpoint(.get, ["me", "entitlement"]), as: EntitlementResponse.self)
    }

    // MARK: Blocks and hides

    public func blockedUsers() async throws -> [UserSummary] {
        try await send(GroupEndpoint(.get, ["me", "blocks"]), as: [UserSummary].self)
    }

    public func block(userID: UUID) async throws {
        try await send(GroupEndpoint(.put, ["me", "blocks", userID.pilgrimString]))
    }

    public func unblock(userID: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["me", "blocks", userID.pilgrimString]))
    }

    public func hides() async throws -> HidesResponse {
        try await send(GroupEndpoint(.get, ["me", "hides"]), as: HidesResponse.self)
    }

    public func hidePost(id: UUID) async throws {
        try await send(GroupEndpoint(.put, ["me", "hides", "posts", id.pilgrimString]))
    }

    public func unhidePost(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["me", "hides", "posts", id.pilgrimString]))
    }

    public func hideUser(id: UUID) async throws {
        try await send(GroupEndpoint(.put, ["me", "hides", "users", id.pilgrimString]))
    }

    public func unhideUser(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["me", "hides", "users", id.pilgrimString]))
    }

    // MARK: Subscriptions

    public func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
    {
        try await send(
            .json(.post, ["subscriptions", "verify"], request), as: EntitlementResponse.self)
    }

    // MARK: Media

    public func upload(_ upload: GroupMediaUpload) async throws -> MediaRef {
        let form = GroupMediaUploader.multipartForm(for: upload)
        let response = try await send(
            GroupEndpoint(.post, ["uploads"], body: .multipart(form)), as: UploadResponse.self)
        return response.media
    }

    public func mediaURL(id: UUID) async throws -> MediaURLResponse {
        try await send(GroupEndpoint(.get, ["media", id.pilgrimString]), as: MediaURLResponse.self)
    }

    // MARK: Groups and members

    public func groups() async throws -> [GroupSummary] {
        try await send(GroupEndpoint(.get, ["groups"]), as: [GroupSummary].self)
    }

    public func createGroup(_ request: CreateGroupRequest) async throws -> GroupDetail {
        try await send(.json(.post, ["groups"], request), as: GroupDetail.self)
    }

    public func group(id: UUID) async throws -> GroupDetail {
        try await send(GroupEndpoint(.get, ["groups", id.pilgrimString]), as: GroupDetail.self)
    }

    public func updateGroup(id: UUID, _ request: UpdateGroupRequest) async throws -> GroupDetail {
        try await send(.json(.patch, ["groups", id.pilgrimString], request), as: GroupDetail.self)
    }

    public func deleteGroup(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["groups", id.pilgrimString]))
    }

    public func leaveGroup(id: UUID) async throws {
        try await send(GroupEndpoint(.post, ["groups", id.pilgrimString, "leave"]))
    }

    public func members(groupID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<MemberResponse>
    {
        try await send(
            GroupEndpoint(
                .get, ["groups", groupID.pilgrimString, "members"],
                query: Self.pageQuery(cursor: cursor, limit: limit)),
            as: Page<MemberResponse>.self)
    }

    public func removeMember(groupID: UUID, userID: UUID) async throws {
        try await send(
            GroupEndpoint(
                .delete, ["groups", groupID.pilgrimString, "members", userID.pilgrimString]))
    }

    public func bans(groupID: UUID) async throws -> [BanResponse] {
        try await send(
            GroupEndpoint(.get, ["groups", groupID.pilgrimString, "bans"]), as: [BanResponse].self)
    }

    public func unban(groupID: UUID, userID: UUID) async throws {
        try await send(
            GroupEndpoint(.delete, ["groups", groupID.pilgrimString, "bans", userID.pilgrimString])
        )
    }

    public func transferAdmin(groupID: UUID, _ request: TransferAdminRequest) async throws
        -> GroupDetail
    {
        try await send(
            .json(.post, ["groups", groupID.pilgrimString, "admin", "transfer"], request),
            as: GroupDetail.self)
    }

    public func markSeen(groupID: UUID) async throws {
        try await send(.json(.post, ["groups", groupID.pilgrimString, "seen"], EmptyBody()))
    }

    public func updateNotifications(groupID: UUID, _ settings: GroupNotificationSettings)
        async throws
    {
        try await send(
            .json(.put, ["groups", groupID.pilgrimString, "notifications"], settings))
    }

    // MARK: Admin votes

    public func vote(groupID: UUID) async throws -> VoteResponse {
        try await send(
            GroupEndpoint(.get, ["groups", groupID.pilgrimString, "vote"]), as: VoteResponse.self)
    }

    public func castBallot(groupID: UUID, _ request: CastBallotRequest) async throws
        -> VoteResponse
    {
        try await send(
            .json(.post, ["groups", groupID.pilgrimString, "vote", "ballot"], request),
            as: VoteResponse.self)
    }

    // MARK: Invites

    public func createInvite(groupID: UUID, _ request: CreateInviteRequest) async throws
        -> InviteResponse
    {
        try await send(
            .json(.post, ["groups", groupID.pilgrimString, "invites"], request),
            as: InviteResponse.self)
    }

    public func invites(groupID: UUID) async throws -> [InviteResponse] {
        try await send(
            GroupEndpoint(.get, ["groups", groupID.pilgrimString, "invites"]),
            as: [InviteResponse].self)
    }

    public func revokeInvite(groupID: UUID, code: String) async throws {
        try await send(
            GroupEndpoint(
                .delete, ["groups", groupID.pilgrimString, "invites", Self.inviteSegment(code)]))
    }

    public func invitePreview(code: String) async throws -> InvitePreviewResponse {
        try await send(
            GroupEndpoint(.get, ["invites", Self.inviteSegment(code)]),
            as: InvitePreviewResponse.self)
    }

    public func acceptInvite(code: String) async throws -> GroupDetail {
        try await send(
            .json(.post, ["invites", Self.inviteSegment(code), "accept"], EmptyBody()),
            as: GroupDetail.self)
    }

    // MARK: Posts, comments, reactions

    public func posts(groupID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<PostResponse>
    {
        try await send(
            GroupEndpoint(
                .get, ["groups", groupID.pilgrimString, "posts"],
                query: Self.pageQuery(cursor: cursor, limit: limit)),
            as: Page<PostResponse>.self)
    }

    public func createPost(groupID: UUID, _ request: CreatePostRequest) async throws
        -> PostResponse
    {
        try await send(
            .json(.post, ["groups", groupID.pilgrimString, "posts"], request),
            as: PostResponse.self)
    }

    public func post(id: UUID) async throws -> PostResponse {
        try await send(GroupEndpoint(.get, ["posts", id.pilgrimString]), as: PostResponse.self)
    }

    public func deletePost(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["posts", id.pilgrimString]))
    }

    public func extendPost(id: UUID, _ request: ExtendPostRequest) async throws -> PostResponse {
        try await send(
            .json(.post, ["posts", id.pilgrimString, "extend"], request), as: PostResponse.self)
    }

    public func comments(postID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<CommentResponse>
    {
        try await send(
            GroupEndpoint(
                .get, ["posts", postID.pilgrimString, "comments"],
                query: Self.pageQuery(cursor: cursor, limit: limit)),
            as: Page<CommentResponse>.self)
    }

    public func createComment(postID: UUID, _ request: CreateCommentRequest) async throws
        -> CommentResponse
    {
        try await send(
            .json(.post, ["posts", postID.pilgrimString, "comments"], request),
            as: CommentResponse.self)
    }

    public func deleteComment(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["comments", id.pilgrimString]))
    }

    public func react(postID: UUID, _ request: ReactionRequest) async throws -> [ReactionSummary] {
        try await send(
            .json(.put, ["posts", postID.pilgrimString, "reactions"], request),
            as: [ReactionSummary].self)
    }

    public func removeReaction(postID: UUID, key: ReactionKey) async throws -> [ReactionSummary] {
        try await send(
            GroupEndpoint(
                .delete, ["posts", postID.pilgrimString, "reactions"], query: [key.queryItem]),
            as: [ReactionSummary].self)
    }

    // MARK: Stickers

    public func stickers(groupID: UUID) async throws -> [StickerResponse] {
        try await send(
            GroupEndpoint(.get, ["groups", groupID.pilgrimString, "stickers"]),
            as: [StickerResponse].self)
    }

    public func createSticker(groupID: UUID, _ request: CreateStickerRequest) async throws
        -> StickerResponse
    {
        try await send(
            .json(.post, ["groups", groupID.pilgrimString, "stickers"], request),
            as: StickerResponse.self)
    }

    public func deleteSticker(id: UUID) async throws {
        try await send(GroupEndpoint(.delete, ["stickers", id.pilgrimString]))
    }

    // MARK: Reports

    public func report(_ request: CreateReportRequest) async throws -> ReportReceipt {
        try await send(.json(.post, ["reports"], request), as: ReportReceipt.self)
    }
}

/// The name the plan uses for the production client.
public typealias LiveGroupAPI = URLSessionGroupAPI

// MARK: - Conveniences that fill in the bundle and installation IDs

extension URLSessionGroupAPI {
    /// `POST /auth/apple` with this build's bundle ID and the stored installation ID. The
    /// caller must already have checked that the Apple user matches the journal session.
    @discardableResult
    public func signInWithApple(
        identityToken: String, authorizationCode: String, rawNonce: String
    ) async throws -> AuthSessionResponse {
        try await signInWithApple(
            AppleSignInRequest(
                identityToken: identityToken, authorizationCode: authorizationCode,
                rawNonce: rawNonce, bundleId: bundleID, installationId: installationID))
    }

    /// `POST /auth/dev` (Debug builds with `PILGRIM_DEV_APPLE_USER`, local server only).
    @discardableResult
    public func signInForDevelopment(devUser: String) async throws -> AuthSessionResponse {
        try await signInForDevelopment(
            DevSignInRequest(devUser: devUser, bundleId: bundleID, installationId: installationID)
        )
    }

    /// Logs out with the stored refresh token; without a session it only clears local state.
    public func logOut() async throws {
        guard let credential = await session.currentCredential else {
            await session.signOut()
            return
        }
        try await logOut(
            LogoutRequest(refreshToken: credential.refreshToken, installationId: installationID))
    }
}
