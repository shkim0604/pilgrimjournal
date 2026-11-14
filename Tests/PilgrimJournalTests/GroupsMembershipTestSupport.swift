#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal

/// `PreviewGroupAPI` with a switchable failure: while `failure` is set every call throws it
/// before reaching the preview server. `calls` records what was asked.
actor ScriptedGroupAPI: GroupAPI {
    let base: PreviewGroupAPI
    private(set) var failure: GroupAPIError?
    private(set) var calls: [String] = []

    init(base: PreviewGroupAPI) {
        self.base = base
    }

    func setFailure(_ failure: GroupAPIError?) {
        self.failure = failure
    }

    private func check(_ name: String = #function) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthSessionResponse {
        try check()
        return try await base.signInWithApple(request)
    }
    func signInForDevelopment(_ request: DevSignInRequest) async throws -> AuthSessionResponse {
        try check()
        return try await base.signInForDevelopment(request)
    }
    func refreshSession(_ request: RefreshRequest) async throws -> AuthSessionResponse {
        try check()
        return try await base.refreshSession(request)
    }
    func logOut(_ request: LogoutRequest) async throws {
        try check()
        try await base.logOut(request)
    }
    func me() async throws -> MeResponse {
        try check()
        return try await base.me()
    }
    func updateMe(_ request: UpdateMeRequest) async throws -> MeResponse {
        try check()
        return try await base.updateMe(request)
    }
    func deleteAccount() async throws -> AccountDeletionResponse {
        try check()
        return try await base.deleteAccount()
    }
    func registerDevice(installationID: UUID, _ request: DeviceRegistrationRequest) async throws {
        try check()
        try await base.registerDevice(installationID: installationID, request)
    }
    func unregisterDevice(installationID: UUID) async throws {
        try check()
        try await base.unregisterDevice(installationID: installationID)
    }
    func dailyReport(date: LocalDate?) async throws -> DailyReportResponse {
        try check()
        return try await base.dailyReport(date: date)
    }
    func entitlement() async throws -> EntitlementResponse {
        try check()
        return try await base.entitlement()
    }
    func blockedUsers() async throws -> [UserSummary] {
        try check()
        return try await base.blockedUsers()
    }
    func block(userID: UUID) async throws {
        try check()
        try await base.block(userID: userID)
    }
    func unblock(userID: UUID) async throws {
        try check()
        try await base.unblock(userID: userID)
    }
    func hides() async throws -> HidesResponse {
        try check()
        return try await base.hides()
    }
    func hidePost(id: UUID) async throws {
        try check()
        try await base.hidePost(id: id)
    }
    func unhidePost(id: UUID) async throws {
        try check()
        try await base.unhidePost(id: id)
    }
    func hideUser(id: UUID) async throws {
        try check()
        try await base.hideUser(id: id)
    }
    func unhideUser(id: UUID) async throws {
        try check()
        try await base.unhideUser(id: id)
    }
    func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
    {
        try check()
        return try await base.verifySubscription(request)
    }
    func upload(_ upload: GroupMediaUpload) async throws -> MediaRef {
        try check()
        return try await base.upload(upload)
    }
    func mediaURL(id: UUID) async throws -> MediaURLResponse {
        try check()
        return try await base.mediaURL(id: id)
    }
    func groups() async throws -> [GroupSummary] {
        try check()
        return try await base.groups()
    }
    func createGroup(_ request: CreateGroupRequest) async throws -> GroupDetail {
        try check()
        return try await base.createGroup(request)
    }
    func group(id: UUID) async throws -> GroupDetail {
        try check()
        return try await base.group(id: id)
    }
    func updateGroup(id: UUID, _ request: UpdateGroupRequest) async throws -> GroupDetail {
        try check()
        return try await base.updateGroup(id: id, request)
    }
    func deleteGroup(id: UUID) async throws {
        try check()
        try await base.deleteGroup(id: id)
    }
    func leaveGroup(id: UUID) async throws {
        try check()
        try await base.leaveGroup(id: id)
    }
    func members(groupID: UUID, cursor: String?, limit: Int?) async throws -> Page<MemberResponse> {
        try check()
        return try await base.members(groupID: groupID, cursor: cursor, limit: limit)
    }
    func removeMember(groupID: UUID, userID: UUID) async throws {
        try check()
        try await base.removeMember(groupID: groupID, userID: userID)
    }
    func bans(groupID: UUID) async throws -> [BanResponse] {
        try check()
        return try await base.bans(groupID: groupID)
    }
    func unban(groupID: UUID, userID: UUID) async throws {
        try check()
        try await base.unban(groupID: groupID, userID: userID)
    }
    func transferAdmin(groupID: UUID, _ request: TransferAdminRequest) async throws -> GroupDetail {
        try check()
        return try await base.transferAdmin(groupID: groupID, request)
    }
    func markSeen(groupID: UUID) async throws {
        try check()
        try await base.markSeen(groupID: groupID)
    }
    func updateNotifications(groupID: UUID, _ settings: GroupNotificationSettings) async throws {
        try check()
        try await base.updateNotifications(groupID: groupID, settings)
    }
    func vote(groupID: UUID) async throws -> VoteResponse {
        try check()
        return try await base.vote(groupID: groupID)
    }
    func castBallot(groupID: UUID, _ request: CastBallotRequest) async throws -> VoteResponse {
        try check()
        return try await base.castBallot(groupID: groupID, request)
    }
    func createInvite(groupID: UUID, _ request: CreateInviteRequest) async throws
        -> InviteResponse
    {
        try check()
        return try await base.createInvite(groupID: groupID, request)
    }
    func invites(groupID: UUID) async throws -> [InviteResponse] {
        try check()
        return try await base.invites(groupID: groupID)
    }
    func revokeInvite(groupID: UUID, code: String) async throws {
        try check()
        try await base.revokeInvite(groupID: groupID, code: code)
    }
    func invitePreview(code: String) async throws -> InvitePreviewResponse {
        try check()
        return try await base.invitePreview(code: code)
    }
    func acceptInvite(code: String) async throws -> GroupDetail {
        try check()
        return try await base.acceptInvite(code: code)
    }
    func posts(groupID: UUID, cursor: String?, limit: Int?) async throws -> Page<PostResponse> {
        try check()
        return try await base.posts(groupID: groupID, cursor: cursor, limit: limit)
    }
    func createPost(groupID: UUID, _ request: CreatePostRequest) async throws -> PostResponse {
        try check()
        return try await base.createPost(groupID: groupID, request)
    }
    func post(id: UUID) async throws -> PostResponse {
        try check()
        return try await base.post(id: id)
    }
    func deletePost(id: UUID) async throws {
        try check()
        try await base.deletePost(id: id)
    }
    func extendPost(id: UUID, _ request: ExtendPostRequest) async throws -> PostResponse {
        try check()
        return try await base.extendPost(id: id, request)
    }
    func comments(postID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<CommentResponse>
    {
        try check()
        return try await base.comments(postID: postID, cursor: cursor, limit: limit)
    }
    func createComment(postID: UUID, _ request: CreateCommentRequest) async throws
        -> CommentResponse
    {
        try check()
        return try await base.createComment(postID: postID, request)
    }
    func deleteComment(id: UUID) async throws {
        try check()
        try await base.deleteComment(id: id)
    }
    func react(postID: UUID, _ request: ReactionRequest) async throws -> [ReactionSummary] {
        try check()
        return try await base.react(postID: postID, request)
    }
    func removeReaction(postID: UUID, key: ReactionKey) async throws -> [ReactionSummary] {
        try check()
        return try await base.removeReaction(postID: postID, key: key)
    }
    func stickers(groupID: UUID) async throws -> [StickerResponse] {
        try check()
        return try await base.stickers(groupID: groupID)
    }
    func createSticker(groupID: UUID, _ request: CreateStickerRequest) async throws
        -> StickerResponse
    {
        try check()
        return try await base.createSticker(groupID: groupID, request)
    }
    func deleteSticker(id: UUID) async throws {
        try check()
        try await base.deleteSticker(id: id)
    }
    func report(_ request: CreateReportRequest) async throws -> ReportReceipt {
        try check()
        return try await base.report(request)
    }
}

/// Answers every Apple request with a fixed credential and remembers the hashed nonces.
@MainActor
final class FakeGroupAppleAuthorizer: GroupAppleAuthorizing {
    var user: String
    var failure: (any Error)?
    private(set) var hashedNonces: [String] = []

    init(user: String, failure: (any Error)? = nil) {
        self.user = user
        self.failure = failure
    }

    func requestCredential(hashedNonce: String) async throws -> GroupAppleCredential {
        hashedNonces.append(hashedNonce)
        if let failure { throw failure }
        return GroupAppleCredential(
            user: user, identityToken: Data("identity-token".utf8),
            authorizationCode: Data("authorization-code".utf8))
    }
}

@MainActor
enum GroupsMembershipFixtures {
    static let journalUser = "001234.journal-apple-user"

    static func controller(
        api: any GroupAPI,
        authorizer: FakeGroupAppleAuthorizer = FakeGroupAppleAuthorizer(user: journalUser),
        credentials: InMemoryGroupSecureItemStore = InMemoryGroupSecureItemStore(),
        invites: PendingGroupInvite = PendingGroupInvite(isEnabled: true),
        journalUser: String? = journalUser
    ) -> GroupsController {
        GroupsController(
            api: api,
            invites: invites,
            notifications: GroupNotificationRouting(isEnabled: true),
            authorizer: authorizer,
            credentials: credentials,
            journalAppleUserIdentifier: { journalUser },
            developmentAppleUser: nil,
            bundleID: BundleIDs.debug)
    }
}
#endif
