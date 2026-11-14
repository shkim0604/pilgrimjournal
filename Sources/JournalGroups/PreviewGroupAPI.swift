import Foundation
import PilgrimAPI

/// An in-memory group server for UI work, previews and tests.
///
/// It follows the server rules closely enough that screens see realistic data and errors:
/// expiry through `PostExpiryPolicy` (expired posts disappear), admin votes through
/// `AdminVoteRules`, invites with use counts and expiry, idempotent `clientId` writes, hides and
/// blocks applied to feeds, comments and reaction counts, stickers, and a computed Daily Report.
/// Time can be moved forward with `advanceTime(by:)`; due votes, deletions and expiries are
/// processed at the start of every call, the way the worker would.
///
/// Only the signed-in user acts. Seeded members never vote or post on their own; tests drive
/// them with `simulateBallot` and `simulatePost`.
public actor PreviewGroupAPI: GroupAPI {
    /// A valid invite code into the seeded group the user is not a member of yet.
    public static let sampleInviteCode = "PREV1EW0C0DE"
    public static let previewBaseURL = URL(string: "https://pilgrim.delight-house.org")!

    // MARK: State

    private struct User {
        var id: UUID
        var displayName: String?
        var profilePhotoID: UUID?
    }

    private struct Membership {
        var joinedAt: Date
        var lastSeenAt: Date?
        var notifications = GroupNotificationSettings()
    }

    private struct Vote {
        var round: Int
        var startedAt: Date
        var endsAt: Date
        var candidates: [UUID]
        var ballots: [UUID: UUID] = [:]
    }

    private struct Group {
        var id: UUID
        var name: String
        var status: GroupStatus = .active
        var adminID: UUID?
        var createdByID: UUID?
        var createdAt: Date
        var members: [UUID: Membership] = [:]
        var bans: [UUID: Date] = [:]
        var deleteAt: Date?
        var deletionReason: GroupDeletionReason?
        var vote: Vote?
    }

    private struct Invite {
        var code: String
        var groupID: UUID
        var createdByID: UUID?
        var maxUses: Int
        var useCount = 0
        var createdAt: Date
        var expiresAt: Date
        var revokedAt: Date?
    }

    private struct Post {
        var id: UUID
        var groupID: UUID
        var authorID: UUID
        var request: CreatePostRequest
        var createdAt: Date
        var expiresAt: Date
        var extensions: [Date] = []
        var mediaIDs: [UUID]
    }

    private struct Comment {
        var id: UUID
        var postID: UUID
        var authorID: UUID
        var body: String
        var mediaIDs: [UUID]
        var stickerID: UUID?
        var hadSticker: Bool
        var createdAt: Date
    }

    private struct Reaction {
        var postID: UUID
        var userID: UUID
        var key: ReactionKey
        var createdAt: Date
    }

    private struct Sticker {
        var id: UUID
        var groupID: UUID
        var createdByID: UUID
        var mediaID: UUID
        var name: String?
        var createdAt: Date
    }

    private struct Media {
        var id: UUID
        var uploaderID: UUID
        var purpose: MediaPurpose
        var data: Data
        var width: Int
        var height: Int
        var attached = false
    }

    private enum Resource: Hashable {
        case group, post, extend, comment, sticker, upload, report
    }

    private let clock: @Sendable () -> Date
    private let policy: PostExpiryPolicy
    private var timeOffset: TimeInterval = 0
    private var random: SeededRandom

    private var meID: UUID
    private var meCreatedAt: Date
    private var timeZoneName = "Asia/Seoul"
    private var dailyReportEnabled = true
    private var dailyReportTime = LocalTime.defaultDailyReport
    private var signedIn: Bool
    private var accountDeleted = false
    private var refreshToken = UUID().pilgrimString

    private var users: [UUID: User] = [:]
    private var groupsByID: [UUID: Group] = [:]
    private var invitesByCode: [String: Invite] = [:]
    private var postsByID: [UUID: Post] = [:]
    private var commentsByID: [UUID: Comment] = [:]
    private var reactions: [Reaction] = []
    private var stickersByID: [UUID: Sticker] = [:]
    private var mediaByID: [UUID: Media] = [:]
    private var blockedUserIDs: [UUID: Date] = [:]
    private var hiddenPostIDs: [UUID: Date] = [:]
    private var hiddenUserIDs: [UUID: Date] = [:]
    private var idempotency: [Resource: [UUID: UUID]] = [:]
    private var inviteClientIDs: [UUID: String] = [:]
    private var reportIDs: [UUID: Date] = [:]
    private var devices: [UUID: DeviceRegistrationRequest] = [:]

    // MARK: Setup

    /// - Parameters:
    ///   - now: the clock (inject a fixed one in tests).
    ///   - dayLength: `TIME_SCALE_DAY_SECONDS`.
    ///   - seeded: start with sample members, two groups, posts and an invite.
    ///   - signedIn: start with a complete group session.
    ///   - randomSeed: drives invite codes and the vote tie-break.
    public init(
        now: @escaping @Sendable () -> Date = { Date() }, dayLength: TimeInterval = 86_400,
        seeded: Bool = true, signedIn: Bool = true, randomSeed: UInt64 = 2026
    ) {
        self.clock = now
        self.policy = PostExpiryPolicy(dayLength: dayLength)
        self.random = SeededRandom(state: randomSeed)
        let meID = UUID()
        self.meID = meID
        self.meCreatedAt = now()
        self.signedIn = signedIn
        var users: [UUID: User] = [:]
        if seeded {
            let seed = Seed(me: meID, now: now(), timeZone: "Asia/Seoul", policy: policy)
            users = seed.users
            self.groupsByID = seed.groups
            self.invitesByCode = seed.invites
            self.postsByID = seed.posts
            self.commentsByID = seed.comments
            self.reactions = seed.reactions
        }
        users[meID] = User(id: meID, displayName: seeded || signedIn ? "나" : nil)
        self.users = users
    }

    /// The signed-in user's ID.
    public var currentUserID: UUID { meID }

    /// Moves the preview clock forward (expiry, votes, invite lifetimes).
    public func advanceTime(by interval: TimeInterval) {
        timeOffset += interval
    }

    /// Records a ballot from another member, as if they voted.
    public func simulateBallot(groupID: UUID, voterID: UUID, candidateID: UUID) throws {
        guard var group = groupsByID[groupID], var vote = group.vote,
            group.members[voterID] != nil
        else { throw GroupAPIError.server(.voteNotOpen) }
        guard vote.candidates.contains(candidateID) else {
            throw GroupAPIError.server(.invalidCandidate)
        }
        vote.ballots[voterID] = candidateID
        group.vote = vote
        groupsByID[groupID] = group
    }

    /// Removes another member, as if they left (an admin leaving starts the election).
    public func simulateLeave(groupID: UUID, userID: UUID) throws {
        guard groupsByID[groupID]?.members[userID] != nil else {
            throw GroupAPIError.server(.notFound)
        }
        _ = removeMembership(of: userID, from: groupID)
    }

    /// Adds a post by another member, as if they posted.
    @discardableResult
    public func simulatePost(groupID: UUID, authorID: UUID, _ request: CreatePostRequest) throws
        -> UUID
    {
        guard groupsByID[groupID]?.members[authorID] != nil else {
            throw GroupAPIError.server(.notFound)
        }
        return try insertPost(groupID: groupID, authorID: authorID, request, at: now).id
    }

    private var now: Date { clock() + timeOffset }

    private var me: UUID { meID }

    /// The sample world: four other members, two groups the user belongs to (one they run), a
    /// third group reachable with `sampleInviteCode`, and a few posts with comments and reactions.
    private struct Seed {
        var users: [UUID: User] = [:]
        var groups: [UUID: Group] = [:]
        var invites: [String: Invite] = [:]
        var posts: [UUID: Post] = [:]
        var comments: [UUID: Comment] = [:]
        var reactions: [Reaction] = []

        init(me: UUID, now start: Date, timeZone: String, policy: PostExpiryPolicy) {
            func addUser(_ name: String) -> UUID {
                let id = UUID()
                users[id] = User(id: id, displayName: name)
                return id
            }
            let minji = addUser("민지")
            let junho = addUser("준호")
            let sua = addUser("수아")
            let haeun = addUser("하은")

            var wednesday = Group(
                id: UUID(), name: "수요 기도모임", adminID: me, createdByID: me,
                createdAt: start - 20 * 86_400)
            for (index, member) in [me, minji, junho, sua].enumerated() {
                wednesday.members[member] = Membership(
                    joinedAt: wednesday.createdAt + Double(index) * 3_600,
                    lastSeenAt: start - 2 * 86_400)
            }
            groups[wednesday.id] = wednesday

            var books = Group(
                id: UUID(), name: "청년부 독서모임", adminID: sua, createdByID: sua,
                createdAt: start - 40 * 86_400)
            for member in [sua, me, haeun] {
                books.members[member] = Membership(joinedAt: books.createdAt, lastSeenAt: start)
            }
            groups[books.id] = books

            var dawn = Group(
                id: UUID(), name: "새벽기도 모임", adminID: haeun, createdByID: haeun,
                createdAt: start - 5 * 86_400)
            dawn.members[haeun] = Membership(joinedAt: dawn.createdAt)
            dawn.members[junho] = Membership(joinedAt: dawn.createdAt)
            groups[dawn.id] = dawn
            invites[PreviewGroupAPI.sampleInviteCode] = Invite(
                code: PreviewGroupAPI.sampleInviteCode, groupID: dawn.id, createdByID: haeun,
                maxUses: 10, useCount: 1, createdAt: start - 3_600,
                expiresAt: start + 3 * 86_400 - 3_600)

            func add(_ groupID: UUID, _ authorID: UUID, _ request: CreatePostRequest, _ at: Date)
                -> UUID
            {
                let expiresAt =
                    (try? policy.expiresAt(
                        kind: request.kind, createdAt: at, deadline: request.deadline,
                        visibleDays: request.visibleDays,
                        timeZone: TimeZone(identifier: request.timeZone) ?? .current))
                    ?? at + 7 * 86_400
                let post = Post(
                    id: UUID(), groupID: groupID, authorID: authorID, request: request,
                    createdAt: at, expiresAt: expiresAt, mediaIDs: [])
                posts[post.id] = post
                return post.id
            }
            let deadline = LocalDate(start, in: TimeZone(identifier: timeZone) ?? .current)
                .adding(days: 5)
            let prayer = add(
                wednesday.id, minji,
                CreatePostRequest(
                    clientId: UUID(), kind: .prayer,
                    items: [
                        PrayerItem(text: "어머니 검사 결과가 좋게 나오도록", topic: "health", who: "엄마"),
                        PrayerItem(text: "이번 주 면접을 차분히 볼 수 있도록", topic: "work"),
                    ],
                    deadline: deadline, timeZone: timeZone, language: "ko"),
                start - 86_400)
            let report = add(
                wednesday.id, junho,
                CreatePostRequest(
                    clientId: UUID(), kind: .bookReport, title: "다시 읽은 고백록",
                    body: "젊은 날의 방황을 이렇게 솔직하게 쓸 수 있다는 게 놀라웠다.",
                    book: BookInfo(title: "고백록", author: "아우구스티누스"), timeZone: timeZone,
                    language: "ko"),
                start - 3 * 86_400)
            _ = add(
                wednesday.id, me,
                CreatePostRequest(
                    clientId: UUID(), kind: .testimony,
                    body: "지난달 기도했던 일이 생각지 못한 방법으로 풀렸어요.", timeZone: timeZone,
                    language: "ko"),
                start - 6 * 3_600)
            _ = add(
                books.id, haeun,
                CreatePostRequest(
                    clientId: UUID(), kind: .bookReport,
                    body: "3장까지 읽었어요. 다음 모임 때 이야기해요.",
                    book: BookInfo(title: "순전한 기독교", author: "C. S. 루이스"),
                    timeZone: timeZone, language: "ko"),
                start - 2 * 86_400)

            let comment = Comment(
                id: UUID(), postID: prayer, authorID: junho, body: "함께 기도할게요 🙏",
                mediaIDs: [], stickerID: nil, hadSticker: false, createdAt: start - 20 * 3_600)
            comments[comment.id] = comment
            reactions = [
                Reaction(
                    postID: prayer, userID: sua, key: .emoji("🙏"), createdAt: start - 19 * 3_600),
                Reaction(
                    postID: prayer, userID: junho, key: .emoji("🙏"),
                    createdAt: start - 19 * 3_600),
                Reaction(
                    postID: report, userID: minji, key: .emoji("❤️"),
                    createdAt: start - 2 * 86_400),
            ]
        }
    }

    // MARK: Auth

    public func signInWithApple(_ request: AppleSignInRequest) async throws -> AuthSessionResponse {
        try startSession(bundleID: request.bundleId)
    }

    public func signInForDevelopment(_ request: DevSignInRequest) async throws
        -> AuthSessionResponse
    {
        try startSession(bundleID: request.bundleId)
    }

    public func refreshSession(_ request: RefreshRequest) async throws -> AuthSessionResponse {
        guard signedIn, request.refreshToken == refreshToken else {
            throw GroupAPIError.server(.refreshTokenInvalid)
        }
        return session()
    }

    public func logOut(_ request: LogoutRequest) async throws {
        try requireSession()
        signedIn = false
        devices[request.installationId] = nil
    }

    private func startSession(bundleID: String) throws -> AuthSessionResponse {
        guard BundleIDs.all.contains(bundleID) else { throw GroupAPIError.server(.invalidRequest) }
        if accountDeleted {
            meID = UUID()
            meCreatedAt = now
            users[meID] = User(id: meID, displayName: nil)
            accountDeleted = false
        }
        signedIn = true
        return session()
    }

    private func session() -> AuthSessionResponse {
        refreshToken = UUID().pilgrimString
        return AuthSessionResponse(
            accessToken: "preview-access-\(UUID().pilgrimString)",
            accessTokenExpiresAt: now + SessionLifetime.accessToken, refreshToken: refreshToken,
            refreshTokenExpiresAt: now + SessionLifetime.refreshToken, user: meResponse())
    }

    // MARK: Me

    public func me() async throws -> MeResponse {
        try requireSession()
        return meResponse()
    }

    public func updateMe(_ request: UpdateMeRequest) async throws -> MeResponse {
        try requireSession()
        if let name = request.displayName {
            try checkName(name, field: "displayName", isValid: APILimits.isValidDisplayName)
            users[me]?.displayName = name
        }
        if let zone = request.timeZone {
            guard TimeZone(identifier: zone) != nil else {
                throw GroupAPIError.server(.validationFailed, field: "timeZone")
            }
            timeZoneName = zone
        }
        if let enabled = request.dailyReportEnabled { dailyReportEnabled = enabled }
        if let time = request.dailyReportTime { dailyReportTime = time }
        if request.removeProfilePhoto == true { users[me]?.profilePhotoID = nil }
        if let photoID = request.profilePhotoId {
            try attach([photoID], purpose: .profile)
            users[me]?.profilePhotoID = photoID
        }
        return meResponse()
    }

    public func deleteAccount() async throws -> AccountDeletionResponse {
        if accountDeleted { return AccountDeletionResponse(deletedAt: nil, alreadyDeleted: true) }
        try requireSession()
        processDueWork()
        var handedToVote: [UUID] = []
        var deleted: [UUID] = []
        for id in groupsByID.keys where groupsByID[id]?.members[me] != nil {
            switch removeMembership(of: me, from: id) {
            case .handedToVote: handedToVote.append(id)
            case .deleted: deleted.append(id)
            case .left: break
            }
        }
        postsByID = postsByID.filter { $0.value.authorID != me }
        commentsByID = commentsByID.filter { $0.value.authorID != me }
        reactions.removeAll { $0.userID == me }
        for sticker in stickersByID.values where sticker.createdByID == me {
            removeSticker(sticker.id)
        }
        mediaByID = mediaByID.filter { $0.value.uploaderID != me }
        blockedUserIDs = [:]
        hiddenPostIDs = [:]
        hiddenUserIDs = [:]
        devices = [:]
        users[me] = nil
        accountDeleted = true
        signedIn = false
        return AccountDeletionResponse(
            deletedAt: now, alreadyDeleted: false,
            groupsHandedToVote: handedToVote.sorted(by: idOrder),
            groupsDeleted: deleted.sorted(by: idOrder))
    }

    public func registerDevice(installationID: UUID, _ request: DeviceRegistrationRequest)
        async throws
    {
        try requireSession()
        devices[installationID] = request
    }

    public func unregisterDevice(installationID: UUID) async throws {
        try requireSession()
        devices[installationID] = nil
    }

    public func dailyReport(date: LocalDate?) async throws -> DailyReportResponse {
        try requireSession()
        processDueWork()
        return buildDailyReport(date: date)
    }

    public func entitlement() async throws -> EntitlementResponse {
        try requireSession()
        return .notRequired
    }

    // MARK: Blocks and hides

    public func blockedUsers() async throws -> [UserSummary] {
        try requireSession()
        return blockedUserIDs.sorted { $0.value < $1.value }.compactMap { userSummary($0.key) }
    }

    public func block(userID: UUID) async throws {
        try requireOtherUser(userID)
        if blockedUserIDs[userID] == nil { blockedUserIDs[userID] = now }
    }

    public func unblock(userID: UUID) async throws {
        try requireSession()
        blockedUserIDs[userID] = nil
    }

    public func hides() async throws -> HidesResponse {
        try requireSession()
        let posts = hiddenPostIDs.sorted { $0.value < $1.value }.compactMap { id, date in
            postsByID[id].flatMap { post in
                groupsByID[post.groupID].map {
                    HiddenPost(
                        postId: id, groupId: $0.id, groupName: $0.name,
                        title: post.request.title, hiddenAt: date)
                }
            }
        }
        let users = hiddenUserIDs.sorted { $0.value < $1.value }.compactMap { id, date in
            userSummary(id).map { HiddenUser(user: $0, hiddenAt: date) }
        }
        return HidesResponse(posts: posts, users: users)
    }

    public func hidePost(id: UUID) async throws {
        try requireSession()
        processDueWork()
        guard let post = postsByID[id], groupsByID[post.groupID]?.members[me] != nil else {
            throw GroupAPIError.server(.notFound)
        }
        if hiddenPostIDs[id] == nil { hiddenPostIDs[id] = now }
    }

    public func unhidePost(id: UUID) async throws {
        try requireSession()
        hiddenPostIDs[id] = nil
    }

    public func hideUser(id: UUID) async throws {
        try requireOtherUser(id)
        if hiddenUserIDs[id] == nil { hiddenUserIDs[id] = now }
    }

    public func unhideUser(id: UUID) async throws {
        try requireSession()
        hiddenUserIDs[id] = nil
    }

    // MARK: Subscriptions

    public func verifySubscription(_ request: VerifySubscriptionRequest) async throws
        -> EntitlementResponse
    {
        try requireSession()
        return EntitlementResponse(
            subscriptionRequired: false, active: true, status: .active,
            productId: SubscriptionProduct.groupsMonthly, expiresAt: now + 30 * 86_400)
    }

    // MARK: Media

    public func upload(_ upload: GroupMediaUpload) async throws -> MediaRef {
        try requireSession()
        if let existing = idempotency[.upload]?[upload.clientID], let media = mediaByID[existing] {
            return mediaRef(media)
        }
        if upload.purpose != .profile {
            guard let groupID = upload.groupID, groupsByID[groupID]?.members[me] != nil else {
                throw GroupAPIError.server(.notFound)
            }
        }
        guard PhotoLimits.hasJPEGSignature(upload.jpegData) else {
            throw GroupAPIError.server(.mediaInvalid)
        }
        do {
            try PhotoLimits.validate(
                purpose: upload.purpose, width: upload.width, height: upload.height,
                byteCount: upload.jpegData.count)
        } catch {
            throw GroupAPIError.server(error.code)
        }
        let media = Media(
            id: UUID(), uploaderID: me, purpose: upload.purpose, data: upload.jpegData,
            width: upload.width, height: upload.height)
        mediaByID[media.id] = media
        idempotency[.upload, default: [:]][upload.clientID] = media.id
        return mediaRef(media)
    }

    public func mediaURL(id: UUID) async throws -> MediaURLResponse {
        try requireSession()
        guard let media = mediaByID[id] else { throw GroupAPIError.server(.notFound) }
        let ref = mediaRef(media)
        return MediaURLResponse(url: ref.url, expiresAt: ref.urlExpiresAt)
    }

    // MARK: Groups and members

    public func groups() async throws -> [GroupSummary] {
        try requireSession()
        processDueWork()
        return groupsByID.values.filter { $0.members[me] != nil }
            .map(summary)
            .sorted { ($0.latestPostAt ?? .distantPast) > ($1.latestPostAt ?? .distantPast) }
    }

    public func createGroup(_ request: CreateGroupRequest) async throws -> GroupDetail {
        try requireSignedUp()
        processDueWork()
        if let existing = idempotency[.group]?[request.clientId], let group = groupsByID[existing] {
            return detail(group)
        }
        try checkName(request.name, field: "name", isValid: APILimits.isValidGroupName)
        let created = groupsByID.values.filter { $0.createdByID == me }.count
        let joined = groupsByID.values.filter { $0.members[me] != nil }.count
        guard created < APILimits.createdGroupsPerUser, joined < APILimits.joinedGroupsPerUser
        else { throw GroupAPIError.server(.groupLimitReached) }
        var group = Group(
            id: UUID(), name: request.name, adminID: me, createdByID: me, createdAt: now)
        group.members[me] = Membership(joinedAt: now, lastSeenAt: now)
        groupsByID[group.id] = group
        idempotency[.group, default: [:]][request.clientId] = group.id
        return detail(group)
    }

    public func group(id: UUID) async throws -> GroupDetail {
        detail(try member(of: id))
    }

    public func updateGroup(id: UUID, _ request: UpdateGroupRequest) async throws -> GroupDetail {
        var group = try member(of: id)
        try requireAdmin(group)
        try checkName(request.name, field: "name", isValid: APILimits.isValidGroupName)
        group.name = request.name
        groupsByID[id] = group
        return detail(group)
    }

    public func deleteGroup(id: UUID) async throws {
        var group = try member(of: id)
        try requireAdmin(group)
        group.status = .pendingDeletion
        group.deleteAt = now + AdminVoteRules.deletionGrace(dayLength: policy.dayLength)
        group.deletionReason = .adminDeleted
        groupsByID[id] = group
    }

    public func leaveGroup(id: UUID) async throws {
        _ = try member(of: id)
        _ = removeMembership(of: me, from: id)
    }

    public func members(groupID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<MemberResponse>
    {
        let group = try member(of: groupID)
        let members = group.members.sorted {
            ($0.value.joinedAt, $0.key.pilgrimString) < ($1.value.joinedAt, $1.key.pilgrimString)
        }
        .compactMap { id, membership in
            userSummary(id).map {
                MemberResponse(
                    user: $0, isAdmin: group.adminID == id, joinedAt: membership.joinedAt)
            }
        }
        return page(members, cursor: cursor, limit: limit)
    }

    public func removeMember(groupID: UUID, userID: UUID) async throws {
        var group = try member(of: groupID)
        try requireAdmin(group)
        guard userID != me else { throw GroupAPIError.server(.cannotTargetSelf) }
        guard group.members[userID] != nil else { throw GroupAPIError.server(.notFound) }
        group.members[userID] = nil
        group.bans[userID] = now
        groupsByID[groupID] = group
    }

    public func bans(groupID: UUID) async throws -> [BanResponse] {
        let group = try member(of: groupID)
        try requireAdmin(group, allowPendingDeletion: true)
        return group.bans.sorted { $0.value < $1.value }.compactMap { id, date in
            userSummary(id).map { BanResponse(user: $0, bannedAt: date) }
        }
    }

    public func unban(groupID: UUID, userID: UUID) async throws {
        var group = try member(of: groupID)
        try requireAdmin(group, allowPendingDeletion: true)
        group.bans[userID] = nil
        groupsByID[groupID] = group
    }

    public func transferAdmin(groupID: UUID, _ request: TransferAdminRequest) async throws
        -> GroupDetail
    {
        var group = try member(of: groupID)
        try requireAdmin(group)
        guard request.userId != me else { throw GroupAPIError.server(.cannotTargetSelf) }
        guard group.members[request.userId] != nil else { throw GroupAPIError.server(.notFound) }
        group.adminID = request.userId
        groupsByID[groupID] = group
        return detail(group)
    }

    public func markSeen(groupID: UUID) async throws {
        _ = try member(of: groupID)
        groupsByID[groupID]?.members[me]?.lastSeenAt = now
    }

    public func updateNotifications(groupID: UUID, _ settings: GroupNotificationSettings)
        async throws
    {
        _ = try member(of: groupID)
        groupsByID[groupID]?.members[me]?.notifications = settings
    }

    // MARK: Admin votes

    public func vote(groupID: UUID) async throws -> VoteResponse {
        let group = try member(of: groupID)
        guard let vote = group.vote else { throw GroupAPIError.server(.notFound) }
        return voteResponse(vote, in: group)
    }

    public func castBallot(groupID: UUID, _ request: CastBallotRequest) async throws
        -> VoteResponse
    {
        var group = try member(of: groupID)
        guard var vote = group.vote else { throw GroupAPIError.server(.voteNotOpen) }
        guard vote.candidates.contains(request.candidateUserId),
            group.members[request.candidateUserId] != nil
        else { throw GroupAPIError.server(.invalidCandidate) }
        vote.ballots[me] = request.candidateUserId
        group.vote = vote
        groupsByID[groupID] = group
        return voteResponse(vote, in: group)
    }

    // MARK: Invites

    public func createInvite(groupID: UUID, _ request: CreateInviteRequest) async throws
        -> InviteResponse
    {
        let group = try member(of: groupID)
        try requireAdmin(group)
        if let code = inviteClientIDs[request.clientId], let invite = invitesByCode[code] {
            return inviteResponse(invite)
        }
        guard APILimits.inviteMaxUses.contains(request.maxUses) else {
            throw GroupAPIError.limit(field: "maxUses", limit: APILimits.inviteMaxUses.upperBound)
        }
        guard activeInvites(groupID).count < APILimits.activeInvitesPerGroup else {
            throw GroupAPIError.server(.inviteLimitReached)
        }
        let code = InviteCode.generate(using: &random).rawValue
        let invite = Invite(
            code: code, groupID: groupID, createdByID: me, maxUses: request.maxUses,
            createdAt: now,
            expiresAt: now + Double(APILimits.inviteLifetimeDays) * policy.dayLength)
        invitesByCode[code] = invite
        inviteClientIDs[request.clientId] = code
        return inviteResponse(invite)
    }

    public func invites(groupID: UUID) async throws -> [InviteResponse] {
        let group = try member(of: groupID)
        try requireAdmin(group, allowPendingDeletion: true)
        return activeInvites(groupID).sorted { $0.createdAt > $1.createdAt }.map(inviteResponse)
    }

    public func revokeInvite(groupID: UUID, code: String) async throws {
        let group = try member(of: groupID)
        try requireAdmin(group, allowPendingDeletion: true)
        guard let normalized = InviteCode(normalizing: code)?.rawValue,
            invitesByCode[normalized]?.groupID == groupID
        else { throw GroupAPIError.server(.notFound) }
        invitesByCode[normalized]?.revokedAt = now
    }

    public func invitePreview(code: String) async throws -> InvitePreviewResponse {
        try requireSession()
        processDueWork()
        let invite = try usableInvite(code)
        guard let group = groupsByID[invite.groupID] else { throw GroupAPIError.server(.notFound) }
        return InvitePreviewResponse(
            code: invite.code, groupId: group.id, groupName: group.name,
            memberCount: group.members.count, invitedBy: invite.createdByID.flatMap(userSummary),
            expiresAt: invite.expiresAt, alreadyMember: group.members[me] != nil,
            requiresSubscription: false)
    }

    public func acceptInvite(code: String) async throws -> GroupDetail {
        try requireSignedUp()
        processDueWork()
        guard let normalized = InviteCode(normalizing: code)?.rawValue,
            let invite = invitesByCode[normalized], var group = groupsByID[invite.groupID]
        else { throw GroupAPIError.server(.notFound) }
        if group.members[me] != nil { return detail(group) }
        if group.bans[me] != nil { throw GroupAPIError.server(.removedFromGroup) }
        switch group.status {
        case .voting: throw GroupAPIError.server(.adminVoteInProgress)
        case .pendingDeletion: throw GroupAPIError.server(.groupPendingDeletion)
        case .active: break
        }
        _ = try usableInvite(normalized)
        guard invite.useCount < invite.maxUses else { throw GroupAPIError.server(.inviteFull) }
        guard
            groupsByID.values.filter({ $0.members[me] != nil }).count
                < APILimits.joinedGroupsPerUser
        else { throw GroupAPIError.server(.groupLimitReached) }
        invitesByCode[normalized]?.useCount += 1
        group.members[me] = Membership(joinedAt: now)
        groupsByID[group.id] = group
        return detail(group)
    }

    // MARK: Posts

    public func posts(groupID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<PostResponse>
    {
        _ = try member(of: groupID)
        let posts = postsByID.values.filter { $0.groupID == groupID && isVisible($0) }
            .sorted { ($0.createdAt, $0.id.pilgrimString) > ($1.createdAt, $1.id.pilgrimString) }
            .map(postResponse)
        return page(posts, cursor: cursor, limit: limit)
    }

    public func createPost(groupID: UUID, _ request: CreatePostRequest) async throws
        -> PostResponse
    {
        try requireSignedUp()
        let group = try member(of: groupID)
        try requireWritable(group)
        if let existing = idempotency[.post]?[request.clientId], let post = postsByID[existing] {
            return postResponse(post)
        }
        try validate(request)
        let post = try insertPost(groupID: groupID, authorID: me, request, at: now)
        idempotency[.post, default: [:]][request.clientId] = post.id
        return postResponse(post)
    }

    public func post(id: UUID) async throws -> PostResponse {
        postResponse(try visiblePost(id))
    }

    public func deletePost(id: UUID) async throws {
        let post = try visiblePost(id)
        try requireAuthorOrAdmin(authorID: post.authorID, groupID: post.groupID)
        deletePostCascade(id)
    }

    public func extendPost(id: UUID, _ request: ExtendPostRequest) async throws -> PostResponse {
        var post = try visiblePost(id)
        if idempotency[.extend]?[request.clientId] == id { return postResponse(post) }
        guard post.request.kind == .bookReport else {
            throw GroupAPIError.server(.extendNotAllowed)
        }
        post.expiresAt = policy.extended(post.expiresAt)
        post.extensions.append(now)
        postsByID[id] = post
        idempotency[.extend, default: [:]][request.clientId] = id
        return postResponse(post)
    }

    // MARK: Comments

    public func comments(postID: UUID, cursor: String?, limit: Int?) async throws
        -> Page<CommentResponse>
    {
        _ = try visiblePost(postID)
        let comments = visibleComments(of: postID).map(commentResponse)
        return page(comments, cursor: cursor, limit: limit)
    }

    public func createComment(postID: UUID, _ request: CreateCommentRequest) async throws
        -> CommentResponse
    {
        try requireSignedUp()
        let post = try visiblePost(postID)
        try requireWritable(groupsByID[post.groupID]!)
        if let existing = idempotency[.comment]?[request.clientId],
            let comment = commentsByID[existing]
        {
            return commentResponse(comment)
        }
        guard request.body.count <= APILimits.commentBodyMax else {
            throw GroupAPIError.limit(field: "body", limit: APILimits.commentBodyMax)
        }
        guard request.mediaIds.count <= APILimits.photosPerComment else {
            throw GroupAPIError.limit(field: "mediaIds", limit: APILimits.photosPerComment)
        }
        let hasBody = !request.body.allSatisfy(\.isWhitespace)
        guard hasBody || !request.mediaIds.isEmpty || request.stickerId != nil else {
            throw GroupAPIError.server(.validationFailed, field: "body")
        }
        if let stickerID = request.stickerId {
            guard stickersByID[stickerID]?.groupID == post.groupID else {
                throw GroupAPIError.server(.notFound)
            }
        }
        try attach(request.mediaIds, purpose: .comment)
        let comment = Comment(
            id: UUID(), postID: postID, authorID: me, body: request.body,
            mediaIDs: request.mediaIds, stickerID: request.stickerId,
            hadSticker: request.stickerId != nil, createdAt: now)
        commentsByID[comment.id] = comment
        idempotency[.comment, default: [:]][request.clientId] = comment.id
        return commentResponse(comment)
    }

    public func deleteComment(id: UUID) async throws {
        guard let comment = commentsByID[id] else { throw GroupAPIError.server(.notFound) }
        let post = try visiblePost(comment.postID)
        guard isVisibleUser(comment.authorID) else { throw GroupAPIError.server(.notFound) }
        try requireAuthorOrAdmin(authorID: comment.authorID, groupID: post.groupID)
        commentsByID[id] = nil
        mediaByID = mediaByID.filter { !comment.mediaIDs.contains($0.key) }
    }

    // MARK: Reactions

    public func react(postID: UUID, _ request: ReactionRequest) async throws -> [ReactionSummary] {
        let post = try visiblePost(postID)
        try requireWritable(groupsByID[post.groupID]!)
        switch request.key {
        case .emoji(let emoji):
            guard APILimits.isReactionEmoji(emoji) else {
                throw GroupAPIError.server(.validationFailed, field: "key")
            }
        case .sticker(let stickerID):
            guard stickersByID[stickerID]?.groupID == post.groupID else {
                throw GroupAPIError.server(.notFound)
            }
        }
        let mine = reactions.filter { $0.postID == postID && $0.userID == me }
        if !mine.contains(where: { $0.key == request.key }) {
            guard mine.count < APILimits.reactionsPerUserPerPost else {
                throw GroupAPIError.limit(field: "key", limit: APILimits.reactionsPerUserPerPost)
            }
            reactions.append(
                Reaction(postID: postID, userID: me, key: request.key, createdAt: now))
        }
        return reactionSummaries(postID)
    }

    public func removeReaction(postID: UUID, key: ReactionKey) async throws -> [ReactionSummary] {
        _ = try visiblePost(postID)
        reactions.removeAll { $0.postID == postID && $0.userID == me && $0.key == key }
        return reactionSummaries(postID)
    }

    // MARK: Stickers

    public func stickers(groupID: UUID) async throws -> [StickerResponse] {
        _ = try member(of: groupID)
        return stickersByID.values.filter { $0.groupID == groupID }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap(stickerResponse)
    }

    public func createSticker(groupID: UUID, _ request: CreateStickerRequest) async throws
        -> StickerResponse
    {
        try requireSignedUp()
        let group = try member(of: groupID)
        try requireWritable(group)
        if let existing = idempotency[.sticker]?[request.clientId],
            let sticker = stickersByID[existing], let response = stickerResponse(sticker)
        {
            return response
        }
        if let name = request.name, name.count > APILimits.stickerNameMax {
            throw GroupAPIError.limit(field: "name", limit: APILimits.stickerNameMax)
        }
        guard
            stickersByID.values.filter({ $0.groupID == groupID }).count
                < APILimits.stickersPerGroup
        else { throw GroupAPIError.server(.stickerLimitReached) }
        try attach([request.mediaId], purpose: .sticker)
        let sticker = Sticker(
            id: UUID(), groupID: groupID, createdByID: me, mediaID: request.mediaId,
            name: request.name, createdAt: now)
        stickersByID[sticker.id] = sticker
        idempotency[.sticker, default: [:]][request.clientId] = sticker.id
        return stickerResponse(sticker)!
    }

    public func deleteSticker(id: UUID) async throws {
        guard let sticker = stickersByID[id] else { throw GroupAPIError.server(.notFound) }
        _ = try member(of: sticker.groupID)
        try requireAuthorOrAdmin(authorID: sticker.createdByID, groupID: sticker.groupID)
        removeSticker(id)
    }

    // MARK: Reports

    public func report(_ request: CreateReportRequest) async throws -> ReportReceipt {
        try requireSession()
        if let existing = idempotency[.report]?[request.clientId], let date = reportIDs[existing] {
            return ReportReceipt(id: existing, createdAt: date)
        }
        if let note = request.note, note.count > APILimits.reportNoteMax {
            throw GroupAPIError.limit(field: "note", limit: APILimits.reportNoteMax)
        }
        if request.targetType == .user, request.targetId == me {
            throw GroupAPIError.server(.cannotTargetSelf)
        }
        guard groupsByID[request.groupId]?.members[me] != nil else {
            throw GroupAPIError.server(.notFound)
        }
        let id = UUID()
        reportIDs[id] = now
        idempotency[.report, default: [:]][request.clientId] = id
        return ReportReceipt(id: id, createdAt: now)
    }

    // MARK: - Rules

    private func requireSession() throws {
        guard signedIn, !accountDeleted else { throw GroupAPIError.notSignedIn }
    }

    private func requireSignedUp() throws {
        try requireSession()
        guard users[me]?.displayName != nil else { throw GroupAPIError.server(.signupRequired) }
    }

    private func requireOtherUser(_ id: UUID) throws {
        try requireSession()
        guard id != me else { throw GroupAPIError.server(.cannotTargetSelf) }
        guard users[id] != nil else { throw GroupAPIError.server(.notFound) }
    }

    /// The group, if the user is a member (404 otherwise, so non-members learn nothing).
    private func member(of groupID: UUID) throws -> Group {
        try requireSession()
        processDueWork()
        guard let group = groupsByID[groupID], group.members[me] != nil else {
            throw GroupAPIError.server(.notFound)
        }
        return group
    }

    private func requireAdmin(_ group: Group, allowPendingDeletion: Bool = false) throws {
        if group.status == .voting { throw GroupAPIError.server(.adminVoteInProgress) }
        guard group.adminID == me else { throw GroupAPIError.server(.forbidden) }
        if group.status == .pendingDeletion, !allowPendingDeletion {
            throw GroupAPIError.server(.groupPendingDeletion)
        }
    }

    private func requireWritable(_ group: Group) throws {
        if group.status == .pendingDeletion { throw GroupAPIError.server(.groupPendingDeletion) }
    }

    /// Authors delete their own things; deleting someone else's is an admin action.
    private func requireAuthorOrAdmin(authorID: UUID, groupID: UUID) throws {
        guard authorID != me else { return }
        guard let group = groupsByID[groupID] else { throw GroupAPIError.server(.notFound) }
        try requireAdmin(group, allowPendingDeletion: true)
    }

    private func checkName(_ name: String, field: String, isValid: (String) -> Bool) throws {
        guard !isValid(name) else { return }
        let limit =
            field == "name" ? APILimits.groupName.upperBound : APILimits.displayName.upperBound
        if name.count > limit { throw GroupAPIError.limit(field: field, limit: limit) }
        throw GroupAPIError.server(.validationFailed, field: field)
    }

    private func validate(_ request: CreatePostRequest) throws {
        if let title = request.title, title.count > APILimits.postTitleMax {
            throw GroupAPIError.limit(field: "title", limit: APILimits.postTitleMax)
        }
        if let body = request.body, body.count > APILimits.postBodyMax {
            throw GroupAPIError.limit(field: "body", limit: APILimits.postBodyMax)
        }
        if request.mediaIds.count > APILimits.photosPerPost {
            throw GroupAPIError.limit(field: "mediaIds", limit: APILimits.photosPerPost)
        }
        guard TimeZone(identifier: request.timeZone) != nil else {
            throw GroupAPIError.server(.validationFailed, field: "timeZone")
        }
        let hasBody = !(request.body ?? "").allSatisfy(\.isWhitespace)
        switch request.kind {
        case .prayer:
            guard request.book == nil else {
                throw GroupAPIError.server(.validationFailed, field: "book")
            }
            let items = request.items ?? []
            guard !items.isEmpty else {
                throw GroupAPIError.server(.validationFailed, field: "items")
            }
            guard items.count <= APILimits.prayerItems.upperBound else {
                throw GroupAPIError.limit(field: "items", limit: APILimits.prayerItems.upperBound)
            }
            for item in items {
                guard !item.text.allSatisfy(\.isWhitespace) else {
                    throw GroupAPIError.server(.validationFailed, field: "items")
                }
                if item.text.count > APILimits.prayerItemTextMax {
                    throw GroupAPIError.limit(field: "items", limit: APILimits.prayerItemTextMax)
                }
                if let who = item.who, who.count > APILimits.prayerItemWhoMax {
                    throw GroupAPIError.limit(field: "items", limit: APILimits.prayerItemWhoMax)
                }
            }
        case .bookReport, .testimony:
            guard request.items == nil else {
                throw GroupAPIError.server(.validationFailed, field: "items")
            }
            guard hasBody else { throw GroupAPIError.server(.validationFailed, field: "body") }
            if request.kind == .testimony, request.book != nil {
                throw GroupAPIError.server(.validationFailed, field: "book")
            }
            if request.kind == .bookReport {
                guard let book = request.book, !book.title.allSatisfy(\.isWhitespace) else {
                    throw GroupAPIError.server(.validationFailed, field: "book")
                }
                if book.title.count > APILimits.bookTitleMax {
                    throw GroupAPIError.limit(field: "book", limit: APILimits.bookTitleMax)
                }
                if let author = book.author, author.count > APILimits.bookAuthorMax {
                    throw GroupAPIError.limit(field: "book", limit: APILimits.bookAuthorMax)
                }
            }
        }
    }

    private func insertPost(
        groupID: UUID, authorID: UUID, _ request: CreatePostRequest, at createdAt: Date
    ) throws -> Post {
        let expiresAt: Date
        do {
            expiresAt = try policy.expiresAt(
                kind: request.kind, createdAt: createdAt, deadline: request.deadline,
                visibleDays: request.visibleDays,
                timeZone: TimeZone(identifier: request.timeZone) ?? .current)
        } catch let error as PostExpiryError {
            throw GroupAPIError.server(status: 422, error: error.apiError)
        }
        if authorID == me { try attach(request.mediaIds, purpose: .post) }
        let post = Post(
            id: UUID(), groupID: groupID, authorID: authorID, request: request,
            createdAt: createdAt, expiresAt: expiresAt, mediaIDs: request.mediaIds)
        postsByID[post.id] = post
        return post
    }

    private func attach(_ mediaIDs: [UUID], purpose: MediaPurpose) throws {
        for id in mediaIDs {
            guard let media = mediaByID[id], media.uploaderID == me, !media.attached,
                media.purpose == purpose
            else { throw GroupAPIError.server(.mediaNotAttachable) }
        }
        for id in mediaIDs { mediaByID[id]?.attached = true }
    }

    private func usableInvite(_ code: String) throws -> Invite {
        guard let normalized = InviteCode(normalizing: code)?.rawValue,
            let invite = invitesByCode[normalized]
        else { throw GroupAPIError.server(.notFound) }
        if invite.revokedAt != nil { throw GroupAPIError.server(.inviteRevoked) }
        if invite.expiresAt <= now { throw GroupAPIError.server(.inviteExpired) }
        return invite
    }

    private func activeInvites(_ groupID: UUID) -> [Invite] {
        invitesByCode.values.filter {
            $0.groupID == groupID && $0.revokedAt == nil && $0.expiresAt > now
        }
    }

    private enum Departure { case left, handedToVote, deleted }

    /// Removes a member; when it is the admin, starts the election (design.md 5절).
    private func removeMembership(of userID: UUID, from groupID: UUID) -> Departure {
        guard var group = groupsByID[groupID] else { return .left }
        group.members[userID] = nil
        if group.members.isEmpty {
            deleteGroupCascade(groupID)
            return .deleted
        }
        guard group.adminID == userID else {
            groupsByID[groupID] = group
            return .left
        }
        group.adminID = nil
        switch AdminVoteRules.start(remainingMembers: Set(group.members.keys)) {
        case .deleteGroup:
            deleteGroupCascade(groupID)
            return .deleted
        case .appoint(let next):
            group.adminID = next
            groupsByID[groupID] = group
            return .left
        case .openVote(let candidates):
            group.status = .voting
            group.vote = openVote(round: 1, candidates: candidates)
            groupsByID[groupID] = group
            return .handedToVote
        }
    }

    private func openVote(round: Int, candidates: [UUID]) -> Vote {
        Vote(
            round: round, startedAt: now,
            endsAt: now + AdminVoteRules.roundLength(round, dayLength: policy.dayLength),
            candidates: candidates)
    }

    /// What the worker does: expire posts, close due votes, delete groups past their grace.
    private func processDueWork() {
        let current = now
        for post in postsByID.values where post.expiresAt <= current {
            deletePostCascade(post.id)
        }
        for var group in groupsByID.values {
            if group.status == .pendingDeletion, let deleteAt = group.deleteAt,
                deleteAt <= current
            {
                deleteGroupCascade(group.id)
                continue
            }
            guard let vote = group.vote, vote.endsAt <= current else { continue }
            let outcome = AdminVoteRules.close(
                round: vote.round, candidates: vote.candidates, ballots: vote.ballots,
                remainingMembers: Set(group.members.keys), using: &random)
            switch outcome {
            case .elect(let admin, _):
                group.adminID = admin
                group.status = .active
                group.vote = nil
            case .runoff(let candidates):
                group.vote = openVote(round: 2, candidates: candidates)
            case .restart(let candidates):
                group.vote = openVote(round: 1, candidates: candidates)
            case .scheduleDeletion:
                group.vote = nil
                group.status = .pendingDeletion
                group.deleteAt = current + AdminVoteRules.deletionGrace(dayLength: policy.dayLength)
                group.deletionReason = .noVotes
            case .deleteGroup:
                deleteGroupCascade(group.id)
                continue
            }
            groupsByID[group.id] = group
        }
    }

    private func deletePostCascade(_ id: UUID) {
        guard let post = postsByID.removeValue(forKey: id) else { return }
        let commentIDs = commentsByID.values.filter { $0.postID == id }
        for comment in commentIDs {
            commentsByID[comment.id] = nil
            for media in comment.mediaIDs { mediaByID[media] = nil }
        }
        reactions.removeAll { $0.postID == id }
        for media in post.mediaIDs { mediaByID[media] = nil }
        hiddenPostIDs[id] = nil
    }

    private func deleteGroupCascade(_ id: UUID) {
        for post in postsByID.values where post.groupID == id { deletePostCascade(post.id) }
        for sticker in stickersByID.values where sticker.groupID == id { removeSticker(sticker.id) }
        invitesByCode = invitesByCode.filter { $0.value.groupID != id }
        groupsByID[id] = nil
    }

    private func removeSticker(_ id: UUID) {
        guard let sticker = stickersByID.removeValue(forKey: id) else { return }
        reactions.removeAll { $0.key == .sticker(id) }
        for comment in commentsByID.values where comment.stickerID == id {
            commentsByID[comment.id]?.stickerID = nil
        }
        mediaByID[sticker.mediaID] = nil
    }

    // MARK: - Visibility

    private func isVisibleUser(_ id: UUID) -> Bool {
        blockedUserIDs[id] == nil && hiddenUserIDs[id] == nil
    }

    private func isVisible(_ post: Post) -> Bool {
        post.expiresAt > now && groupsByID[post.groupID]?.members[me] != nil
            && hiddenPostIDs[post.id] == nil && isVisibleUser(post.authorID)
    }

    private func visiblePost(_ id: UUID) throws -> Post {
        try requireSession()
        processDueWork()
        guard let post = postsByID[id], isVisible(post) else {
            throw GroupAPIError.server(.notFound)
        }
        return post
    }

    private func visibleComments(of postID: UUID) -> [Comment] {
        commentsByID.values.filter { $0.postID == postID && isVisibleUser($0.authorID) }
            .sorted { ($0.createdAt, $0.id.pilgrimString) < ($1.createdAt, $1.id.pilgrimString) }
    }

    private func isUnread(_ post: Post) -> Bool {
        guard post.authorID != me, let membership = groupsByID[post.groupID]?.members[me] else {
            return false
        }
        return post.createdAt > (membership.lastSeenAt ?? membership.joinedAt)
    }

    // MARK: - Responses

    private func meResponse() -> MeResponse {
        let user = users[me]
        return MeResponse(
            id: me, displayName: user?.displayName,
            profilePhoto: user?.profilePhotoID.flatMap { mediaByID[$0] }.map(mediaRef),
            profileComplete: user?.displayName != nil, timeZone: timeZoneName,
            dailyReportEnabled: dailyReportEnabled, dailyReportTime: dailyReportTime,
            createdAt: meCreatedAt, entitlement: .notRequired)
    }

    private func userSummary(_ id: UUID) -> UserSummary? {
        guard let user = users[id] else { return nil }
        return UserSummary(
            id: id, displayName: user.displayName ?? "",
            profilePhoto: user.profilePhotoID.flatMap { mediaByID[$0] }.map(mediaRef))
    }

    private func summary(_ group: Group) -> GroupSummary {
        let posts = postsByID.values.filter { $0.groupID == group.id && isVisible($0) }
        return GroupSummary(
            id: group.id, name: group.name, status: group.status,
            memberCount: group.members.count, isAdmin: group.adminID == me,
            admin: group.adminID.flatMap(userSummary), unreadCount: posts.filter(isUnread).count,
            latestPostAt: posts.map(\.createdAt).max(),
            notifications: group.members[me]?.notifications ?? GroupNotificationSettings(),
            voteEndsAt: group.vote?.endsAt, deleteAt: group.deleteAt)
    }

    private func detail(_ group: Group) -> GroupDetail {
        GroupDetail(
            summary: summary(group), createdAt: group.createdAt,
            createdBy: group.createdByID.flatMap(userSummary),
            deletionReason: group.deletionReason,
            stickerCount: stickersByID.values.filter { $0.groupID == group.id }.count,
            activeInviteCount: group.adminID == me ? activeInvites(group.id).count : nil)
    }

    private func voteResponse(_ vote: Vote, in group: Group) -> VoteResponse {
        let members = Set(group.members.keys)
        return VoteResponse(
            round: vote.round, startedAt: vote.startedAt, endsAt: vote.endsAt,
            candidates: vote.candidates.filter(members.contains).compactMap(userSummary),
            myBallot: vote.ballots[me],
            ballotCount: vote.ballots.keys.filter(members.contains).count,
            eligibleCount: members.count)
    }

    private func inviteResponse(_ invite: Invite) -> InviteResponse {
        InviteResponse(
            code: invite.code,
            url: InviteCode(normalizing: invite.code)!.url(base: Self.previewBaseURL),
            maxUses: invite.maxUses, useCount: invite.useCount, expiresAt: invite.expiresAt,
            createdAt: invite.createdAt, createdBy: invite.createdByID.flatMap(userSummary))
    }

    private func postResponse(_ post: Post) -> PostResponse {
        let request = post.request
        return PostResponse(
            id: post.id, groupId: post.groupID, kind: request.kind,
            author: userSummary(post.authorID) ?? UserSummary(id: post.authorID, displayName: ""),
            isMine: post.authorID == me, title: request.title, body: request.body,
            items: request.items, book: request.book, deadline: request.deadline,
            visibleDays: request.kind == .prayer && request.deadline == nil
                ? (request.visibleDays ?? PostExpiryPolicy.defaultVisibleDays) : nil,
            timeZone: request.timeZone, language: request.language, createdAt: post.createdAt,
            expiresAt: post.expiresAt, extensionCount: post.extensions.count,
            media: post.mediaIDs.compactMap { mediaByID[$0] }.map(mediaRef),
            commentCount: visibleComments(of: post.id).count,
            reactions: reactionSummaries(post.id), isUnread: isUnread(post))
    }

    private func commentResponse(_ comment: Comment) -> CommentResponse {
        CommentResponse(
            id: comment.id, postId: comment.postID,
            author: userSummary(comment.authorID)
                ?? UserSummary(id: comment.authorID, displayName: ""),
            isMine: comment.authorID == me, body: comment.body,
            media: comment.mediaIDs.compactMap { mediaByID[$0] }.map(mediaRef),
            sticker: comment.stickerID.flatMap { stickersByID[$0] }.flatMap(stickerResponse),
            stickerRemoved: comment.hadSticker && comment.stickerID == nil,
            createdAt: comment.createdAt)
    }

    private func stickerResponse(_ sticker: Sticker) -> StickerResponse? {
        guard let media = mediaByID[sticker.mediaID] else { return nil }
        return StickerResponse(
            id: sticker.id, groupId: sticker.groupID, name: sticker.name, media: mediaRef(media),
            createdBy: userSummary(sticker.createdByID), createdAt: sticker.createdAt,
            isMine: sticker.createdByID == me)
    }

    private func reactionSummaries(_ postID: UUID) -> [ReactionSummary] {
        var order: [ReactionKey] = []
        var counts: [ReactionKey: (count: Int, mine: Bool)] = [:]
        for reaction in reactions where reaction.postID == postID {
            guard reaction.userID == me || isVisibleUser(reaction.userID) else { continue }
            if counts[reaction.key] == nil { order.append(reaction.key) }
            let previous = counts[reaction.key] ?? (0, false)
            counts[reaction.key] = (previous.count + 1, previous.mine || reaction.userID == me)
        }
        return order.map {
            ReactionSummary(key: $0, count: counts[$0]!.count, reactedByMe: counts[$0]!.mine)
        }
    }

    /// Preview media URLs are `data:` URLs, so image views load them without a server.
    private func mediaRef(_ media: Media) -> MediaRef {
        let url = URL(string: "data:image/jpeg;base64,\(media.data.base64EncodedString())")!
        return MediaRef(
            id: media.id, width: media.width, height: media.height, byteCount: media.data.count,
            url: url, urlExpiresAt: now + MediaRef.signedURLLifetime)
    }

    private func page<Item>(_ items: [Item], cursor: String?, limit: Int?) -> Page<Item> {
        let start = cursor.flatMap(Int.init).map { max(0, $0) } ?? 0
        let size = min(max(limit ?? Page<Item>.defaultLimit, 1), Page<Item>.maximumLimit)
        let end = min(start + size, items.count)
        let slice = start < end ? Array(items[start..<end]) : []
        return Page(items: slice, nextCursor: end < items.count ? String(end) : nil)
    }

    // MARK: - Daily Report

    private func buildDailyReport(date: LocalDate?) -> DailyReportResponse {
        let zone = TimeZone(identifier: timeZoneName) ?? .current
        let current = now
        let reportDate: LocalDate
        if let date {
            reportDate = date
        } else {
            let today = LocalDate(current, in: zone)
            reportDate = reportInstant(today, zone) <= current ? today : today.adding(days: -1)
        }
        let windowEnd = reportInstant(reportDate, zone)
        let windowStart = windowEnd - 24 * 3_600
        let window = windowStart..<windowEnd

        var groups: [DailyReportGroup] = []
        for group in groupsByID.values.sorted(by: { $0.name < $1.name }) {
            guard let membership = group.members[me], membership.notifications.dailyReportEnabled
            else { continue }
            let posts = postsByID.values.filter { $0.groupID == group.id && isVisible($0) }
                .sorted { $0.createdAt < $1.createdAt }
            func line(_ post: Post, count: Int) -> DailyReportPost {
                DailyReportPost(
                    postId: post.id, kind: post.request.kind,
                    title: DailyReportPost.title(
                        title: post.request.title, book: post.request.book,
                        items: post.request.items, body: post.request.body),
                    author: userSummary(post.authorID)
                        ?? UserSummary(id: post.authorID, displayName: ""),
                    count: count, expiresAt: post.expiresAt)
            }
            var section = DailyReportGroup(groupId: group.id, groupName: group.name)
            for post in posts {
                if post.authorID != me, window.contains(post.createdAt) {
                    section.newPosts.append(line(post, count: 1))
                }
                let comments = visibleComments(of: post.id)
                if post.authorID == me {
                    let newComments = comments.filter {
                        $0.authorID != me && window.contains($0.createdAt)
                    }
                    if !newComments.isEmpty {
                        section.commentsOnMyPosts.append(line(post, count: newComments.count))
                    }
                    let newReactions = reactions.filter {
                        $0.postID == post.id && $0.userID != me && isVisibleUser($0.userID)
                            && window.contains($0.createdAt)
                    }
                    if !newReactions.isEmpty {
                        section.reactionsOnMyPosts.append(line(post, count: newReactions.count))
                    }
                }
                let extensions = post.extensions.filter(window.contains)
                let involved = post.authorID == me || comments.contains { $0.authorID == me }
                if !extensions.isEmpty, involved {
                    section.extendedPosts.append(line(post, count: extensions.count))
                }
                if post.expiresAt > current, post.expiresAt <= current + 24 * 3_600 {
                    section.expiringSoon.append(line(post, count: 1))
                }
            }
            if section.itemCount > 0 { groups.append(section) }
        }
        return DailyReportResponse(
            date: reportDate, windowStart: windowStart, windowEnd: windowEnd,
            totalCount: groups.map(\.itemCount).reduce(0, +), groups: groups)
    }

    /// The report time on `date` in `zone`; a time skipped by DST moves to the next valid one.
    private func reportInstant(_ date: LocalDate, _ zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: date.year, month: date.month, day: date.day, hour: dailyReportTime.hour,
            minute: dailyReportTime.minute)
        return calendar.date(from: components) ?? date.startOfDay(in: zone)
    }

    private func idOrder(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.pilgrimString < rhs.pilgrimString }
}

extension GroupAPIError {
    fileprivate static func limit(field: String, limit: Int) -> GroupAPIError {
        .server(
            status: APIErrorCode.limitExceeded.httpStatus,
            error: APIError(
                code: .limitExceeded, message: "\(field) is over its limit", field: field,
                limit: limit))
    }
}

/// SplitMix64: invite codes and vote tie-breaks reproducible from `randomSeed`.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
