import Foundation
import PilgrimAPI

/// The group server as the app sees it: one async method per `/api/v1` endpoint the app calls
/// (design.md "API"). Operator routes, the App Store webhook and `/api/health` are not here.
///
/// Implementations: `URLSessionGroupAPI` (the real client, with the Keychain session and the
/// single-flight token refresh) and `PreviewGroupAPI` (in memory, for UI work and tests). Every
/// method throws `GroupAPIError`.
public protocol GroupAPI: Sendable {
    // MARK: Auth (no access token)

    func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthSessionResponse
    /// `POST /auth/dev`, Debug builds with `PILGRIM_DEV_APPLE_USER` only.
    func signInForDevelopment(_ request: DevSignInRequest) async throws -> AuthSessionResponse
    func refreshSession(_ request: RefreshRequest) async throws -> AuthSessionResponse
    func logOut(_ request: LogoutRequest) async throws

    // MARK: Me

    func me() async throws -> MeResponse
    func updateMe(_ request: UpdateMeRequest) async throws -> MeResponse
    /// `DELETE /me`. Runs first in account deletion; idempotent (`alreadyDeleted`).
    func deleteAccount() async throws -> AccountDeletionResponse
    func registerDevice(installationID: UUID, _ request: DeviceRegistrationRequest) async throws
    func unregisterDevice(installationID: UUID) async throws
    /// nil `date` → the most recently finished window.
    func dailyReport(date: LocalDate?) async throws -> DailyReportResponse
    func entitlement() async throws -> EntitlementResponse

    // MARK: Blocks and hides

    func blockedUsers() async throws -> [UserSummary]
    func block(userID: UUID) async throws
    func unblock(userID: UUID) async throws
    func hides() async throws -> HidesResponse
    func hidePost(id: UUID) async throws
    func unhidePost(id: UUID) async throws
    func hideUser(id: UUID) async throws
    func unhideUser(id: UUID) async throws

    // MARK: Subscriptions

    func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse

    // MARK: Media

    /// `POST /uploads` (multipart). The JPEG must already be compressed by `ImageCompressor`.
    func upload(_ upload: GroupMediaUpload) async throws -> MediaRef
    /// `GET /media/:id`: a fresh signed URL after the previous one expired.
    func mediaURL(id: UUID) async throws -> MediaURLResponse

    // MARK: Groups and members

    func groups() async throws -> [GroupSummary]
    func createGroup(_ request: CreateGroupRequest) async throws -> GroupDetail
    func group(id: UUID) async throws -> GroupDetail
    func updateGroup(id: UUID, _ request: UpdateGroupRequest) async throws -> GroupDetail
    /// Admin only: `pendingDeletion` with a 7-day grace.
    func deleteGroup(id: UUID) async throws
    func leaveGroup(id: UUID) async throws
    func members(groupID: UUID, cursor: String?, limit: Int?) async throws -> Page<MemberResponse>
    /// Admin only: removes and bans the member.
    func removeMember(groupID: UUID, userID: UUID) async throws
    func bans(groupID: UUID) async throws -> [BanResponse]
    func unban(groupID: UUID, userID: UUID) async throws
    func transferAdmin(groupID: UUID, _ request: TransferAdminRequest) async throws -> GroupDetail
    func markSeen(groupID: UUID) async throws
    func updateNotifications(groupID: UUID, _ settings: GroupNotificationSettings) async throws

    // MARK: Admin votes

    /// The open vote; throws `NOT_FOUND` when there is none.
    func vote(groupID: UUID) async throws -> VoteResponse
    func castBallot(groupID: UUID, _ request: CastBallotRequest) async throws -> VoteResponse

    // MARK: Invites

    func createInvite(groupID: UUID, _ request: CreateInviteRequest) async throws
        -> InviteResponse
    func invites(groupID: UUID) async throws -> [InviteResponse]
    func revokeInvite(groupID: UUID, code: String) async throws
    func invitePreview(code: String) async throws -> InvitePreviewResponse
    func acceptInvite(code: String) async throws -> GroupDetail

    // MARK: Posts, comments, reactions

    /// Newest first.
    func posts(groupID: UUID, cursor: String?, limit: Int?) async throws -> Page<PostResponse>
    func createPost(groupID: UUID, _ request: CreatePostRequest) async throws -> PostResponse
    func post(id: UUID) async throws -> PostResponse
    func deletePost(id: UUID) async throws
    /// Book reports only: +7 days on the current expiry.
    func extendPost(id: UUID, _ request: ExtendPostRequest) async throws -> PostResponse
    /// Oldest first.
    func comments(postID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<CommentResponse>
    func createComment(postID: UUID, _ request: CreateCommentRequest) async throws
        -> CommentResponse
    func deleteComment(id: UUID) async throws
    func react(postID: UUID, _ request: ReactionRequest) async throws -> [ReactionSummary]
    func removeReaction(postID: UUID, key: ReactionKey) async throws -> [ReactionSummary]

    // MARK: Stickers

    func stickers(groupID: UUID) async throws -> [StickerResponse]
    func createSticker(groupID: UUID, _ request: CreateStickerRequest) async throws
        -> StickerResponse
    func deleteSticker(id: UUID) async throws

    // MARK: Reports

    func report(_ request: CreateReportRequest) async throws -> ReportReceipt
}

/// The multipart body of `POST /uploads` (field names in `UploadFormField`).
public struct GroupMediaUpload: Equatable, Sendable {
    public var clientID: UUID
    public var purpose: MediaPurpose
    /// Required for every purpose except `.profile`.
    public var groupID: UUID?
    public var jpegData: Data
    public var width: Int
    public var height: Int

    public init(
        clientID: UUID, purpose: MediaPurpose, groupID: UUID?, jpegData: Data, width: Int,
        height: Int
    ) {
        self.clientID = clientID
        self.purpose = purpose
        self.groupID = groupID
        self.jpegData = jpegData
        self.width = width
        self.height = height
    }
}

/// Why a `GroupAPI` call failed.
public enum GroupAPIError: Error, Equatable, Sendable {
    /// The server answered with an error body. Pick the message from `error.code`.
    case server(status: Int, error: APIError)
    /// No connection to the group server ("그룹 서버에 연결할 수 없어요"). Drafts must be kept.
    case offline
    case timedOut
    /// A response that is not the contract (unexpected status or undecodable body).
    case invalidResponse(status: Int)
    /// No group session; the user has to sign in to groups (again).
    case notSignedIn
    case cancelled

    /// A server error with only a code, as `PreviewGroupAPI` and tests produce it.
    public static func server(_ code: APIErrorCode, message: String? = nil, field: String? = nil)
        -> GroupAPIError
    {
        .server(
            status: code.httpStatus,
            error: APIError(code: code, message: message ?? code.rawValue, field: field))
    }

    /// The server's error code, if the server answered.
    public var code: APIErrorCode? {
        if case .server(_, let error) = self { return error.code }
        return nil
    }

    /// Whether the request may succeed if sent again unchanged later.
    public var isRetryable: Bool {
        switch self {
        case .offline, .timedOut: true
        case .server(let status, let error):
            error.code == .rateLimited || error.code == .serviceUnavailable || status >= 500
        case .invalidResponse, .notSignedIn, .cancelled: false
        }
    }

    /// The group session is no longer usable; clear it and ask to sign in to groups again
    /// (the journal session stays).
    public var requiresGroupSignIn: Bool {
        switch code {
        case .refreshTokenInvalid, .refreshTokenReused, .unauthenticated: true
        default: self == .notSignedIn
        }
    }
}
