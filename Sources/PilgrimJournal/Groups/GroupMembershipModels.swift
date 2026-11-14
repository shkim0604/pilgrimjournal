import Combine
import Foundation
import JournalGroups
import PilgrimAPI

// MARK: - Account state

/// Where this user stands with the group server. The sidebar's 그룹 section shows
/// "그룹 시작하기" until it is `.signedIn` (or `.needsSubscription`, which still lists groups).
enum GroupsAccountState: Equatable {
    /// Not checked yet this launch.
    case unknown
    /// No group session: "그룹 시작하기" (Apple re-auth, then sign-up).
    case signedOut
    /// Signed in to the group server, but the sign-up screen (terms, name, photo) is not done.
    case needsProfile
    /// Signed up, but the server requires a subscription this user does not have.
    case needsSubscription
    case signedIn
    /// 426 `CLIENT_UPGRADE_REQUIRED`: groups need a newer app. The journal is unaffected.
    case upgradeRequired

    /// The state a server profile puts the user in.
    init(me: MeResponse) {
        if !me.profileComplete {
            self = .needsProfile
        } else if me.entitlement.subscriptionRequired, !me.entitlement.active {
            self = .needsSubscription
        } else {
            self = .signedIn
        }
    }

    /// Whether the group list is the user's to see (with or without a subscription).
    var hasGroupAccess: Bool {
        self == .signedIn || self == .needsSubscription
    }

    /// Whether the sidebar shows "그룹 시작하기" (sign-in or sign-up still to do).
    var needsOnboarding: Bool {
        self == .signedOut || self == .needsProfile
    }
}

// MARK: - Sheets

/// The one group sheet on screen. Hosted by `groupsSheets(_:)`.
enum GroupsSheet: Identifiable, Equatable {
    case onboarding
    case createGroup
    case join(GroupJoinRequest)
    case settings(groupID: UUID)
    case invites(groupID: UUID)
    case vote(groupID: UUID)
    /// Placeholder until A8 brings the paywall (`GroupsController.onSubscriptionRequired`).
    case subscription

    var id: String {
        switch self {
        case .onboarding: "onboarding"
        case .createGroup: "create"
        case .join(let request): "join-\(request.id.uuidString)"
        case .settings(let id): "settings-\(id.uuidString)"
        case .invites(let id): "invites-\(id.uuidString)"
        case .vote(let id): "vote-\(id.uuidString)"
        case .subscription: "subscription"
        }
    }
}

/// One opening of the join sheet: a code from a link or QR code, or nil for typing one.
struct GroupJoinRequest: Identifiable, Equatable {
    let id = UUID()
    var code: InviteCode?
}

// MARK: - Admin capabilities

/// What the current member may do in a group. While a vote is open there is no admin, so every
/// admin action is hidden for everyone; during the deletion grace only reading, scrapping,
/// leaving and cleaning up invites and bans remain.
struct GroupAdminCapabilities: Equatable {
    var canRename: Bool
    var canCreateInvites: Bool
    /// List and revoke (allowed during the deletion grace, like the server).
    var canManageInvites: Bool
    var canRemoveMembers: Bool
    var canManageBans: Bool
    var canTransferAdmin: Bool
    var canDeleteGroup: Bool
    var isVoting: Bool
    var isPendingDeletion: Bool

    init(group: GroupSummary) {
        let isActiveAdmin = group.isAdmin && group.status == .active
        let isAdminOutsideVote = group.isAdmin && group.status != .voting
        canRename = isActiveAdmin
        canCreateInvites = isActiveAdmin
        canManageInvites = isAdminOutsideVote
        canRemoveMembers = isActiveAdmin
        canManageBans = isAdminOutsideVote
        canTransferAdmin = isActiveAdmin
        canDeleteGroup = isActiveAdmin
        isVoting = group.status == .voting
        isPendingDeletion = group.status == .pendingDeletion
    }

    /// Whether any admin action is available at all.
    var hasAnyAdminAction: Bool {
        canRename || canManageInvites || canRemoveMembers || canManageBans || canTransferAdmin
            || canDeleteGroup
    }
}

/// How leaving a group goes for this member.
enum GroupLeavePlan: Equatable {
    /// A member, or anyone while there is no admin (voting, deletion grace), just leaves.
    case leave
    /// The admin of a group with other members picks: hand over directly, or leave and let
    /// the members vote.
    case adminChoosesSuccessor
    /// The last member: leaving deletes the group right away.
    case lastMember

    init(group: GroupSummary) {
        if group.memberCount <= 1 {
            self = .lastMember
        } else if group.isAdmin, group.status == .active {
            self = .adminChoosesSuccessor
        } else {
            self = .leave
        }
    }
}

// MARK: - Input rules

enum GroupInviteRules {
    static let maxUsesRange = APILimits.inviteMaxUses
    static let defaultMaxUses = 10
    static let lifetimeDays = APILimits.inviteLifetimeDays

    /// The typed maximum, or nil when it is not a whole number in 1…100.
    static func maxUses(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), maxUsesRange.contains(value) else { return nil }
        return value
    }

    static func isValid(maxUses: Int) -> Bool {
        maxUsesRange.contains(maxUses)
    }

    /// Keeps a stepper value inside 1…100.
    static func clamped(_ value: Int) -> Int {
        min(max(value, maxUsesRange.lowerBound), maxUsesRange.upperBound)
    }
}

enum GroupNameRules {
    /// The name as it is sent: surrounding whitespace dropped.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidGroupName(_ text: String) -> Bool {
        APILimits.isValidGroupName(normalized(text))
    }

    static func isValidDisplayName(_ text: String) -> Bool {
        APILimits.isValidDisplayName(normalized(text))
    }
}

// MARK: - Messages

/// The text for a failed group call. The server's `message` is never shown; the app picks
/// its words from the code.
enum GroupMessages {
    static let offline = String(localized: "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요.")
    static let upgradeRequired = String(localized: "그룹을 쓰려면 앱을 업데이트해 주세요.")
    static let signInAgain = String(localized: "그룹에 다시 로그인해 주세요.")

    static func text(for error: GroupAPIError) -> String {
        switch error {
        case .offline, .timedOut:
            return offline
        case .notSignedIn:
            return signInAgain
        case .cancelled:
            return String(localized: "요청이 취소됐어요.")
        case .invalidResponse:
            return String(localized: "그룹 서버의 응답을 이해하지 못했어요. 잠시 뒤 다시 시도해 주세요.")
        case .server(_, let apiError):
            return text(for: apiError)
        }
    }

    static func text(for error: APIError) -> String {
        switch error.code {
        case .clientUpgradeRequired:
            return upgradeRequired
        case .unauthenticated, .tokenExpired, .refreshTokenInvalid, .refreshTokenReused:
            return signInAgain
        case .appleTokenInvalid, .appleNonceMismatch:
            return String(localized: "Apple 인증을 확인하지 못했어요. 다시 시도해 주세요.")
        case .appleCodeExchangeFailed:
            return String(localized: "Apple 인증을 마치지 못했어요. 잠시 뒤 다시 시도해 주세요.")
        case .signupRequired:
            return String(localized: "그룹을 쓰려면 먼저 가입을 마쳐 주세요.")
        case .accountSuspended:
            return String(localized: "계정이 일시 정지되어 그룹을 쓸 수 없어요.")
        case .forbidden:
            return String(localized: "관리자만 할 수 있어요.")
        case .removedFromGroup:
            return String(localized: "이 그룹에서 내보내져 다시 참여할 수 없어요. 관리자에게 문의해 주세요.")
        case .subscriptionRequired:
            return String(localized: "그룹을 쓰려면 구독이 필요해요.")
        case .notFound:
            return String(localized: "그룹이나 항목을 찾을 수 없어요.")
        case .adminVoteInProgress:
            return String(localized: "새 관리자를 뽑는 중이라 지금은 할 수 없어요.")
        case .groupPendingDeletion:
            return String(localized: "삭제 예정인 그룹이라 할 수 없어요.")
        case .voteNotOpen:
            return String(localized: "투표가 이미 끝났어요.")
        case .invalidCandidate:
            return String(localized: "이 사람에게는 투표할 수 없어요.")
        case .inviteExpired:
            return String(localized: "이 초대는 만료됐어요. 관리자에게 새 초대를 요청해 주세요.")
        case .inviteRevoked:
            return String(localized: "이 초대는 취소됐어요. 관리자에게 새 초대를 요청해 주세요.")
        case .inviteFull:
            return String(localized: "이 초대는 인원이 다 찼어요. 관리자에게 새 초대를 요청해 주세요.")
        case .inviteLimitReached:
            return String(localized: "살아 있는 초대는 그룹당 20개까지예요. 쓰지 않는 초대를 취소해 주세요.")
        case .groupLimitReached:
            return String(localized: "더 이상 그룹을 만들거나 참여할 수 없어요.")
        case .cannotTargetSelf:
            return String(localized: "나 자신에게는 할 수 없어요.")
        case .validationFailed, .limitExceeded, .invalidRequest:
            return String(localized: "입력한 내용을 다시 확인해 주세요.")
        case .mediaInvalid, .mediaTooLarge, .mediaNotAttachable:
            return String(localized: "사진을 올리지 못했어요. 다른 사진을 골라 주세요.")
        case .rateLimited:
            return String(localized: "요청이 너무 많아요. 잠시 뒤 다시 시도해 주세요.")
        case .serviceUnavailable, .internal, .unknown:
            return String(localized: "그룹 서버에 문제가 있어요. 잠시 뒤 다시 시도해 주세요.")
        case .subscriptionInvalid, .subscriptionOwnedByOtherUser:
            return String(localized: "구독을 확인하지 못했어요.")
        case .extendNotAllowed, .stickerLimitReached:
            return String(localized: "지금은 할 수 없어요.")
        }
    }

    /// The join screen's text for a failed preview or accept. A missing invite reads as a
    /// typing mistake, since the server answers 404 for codes it does not know.
    static func joinText(for error: GroupAPIError) -> String {
        switch error.code {
        case .notFound:
            return String(localized: "초대를 찾을 수 없어요. 코드를 다시 확인해 주세요.")
        case .adminVoteInProgress:
            return String(localized: "이 그룹은 새 관리자를 뽑는 중이라 지금은 참여할 수 없어요.")
        case .groupPendingDeletion:
            return String(localized: "이 그룹은 삭제될 예정이라 참여할 수 없어요.")
        default:
            return text(for: error)
        }
    }
}

// MARK: - Dates

enum GroupDateText {
    /// "11월 20일 22:00" style, in the user's locale and time zone.
    static func dayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The App Store page the upgrade notice links to. Phase 2 replaces the search link with the
/// app's own page once its App Store ID is fixed.
enum GroupsAppStoreLink {
    static let url = URL(string: "https://apps.apple.com/search?term=Pilgrim%20Journal")!
}

// MARK: - Sheet models

/// The join sheet: a typed or received code, its preview, and accepting it. Typed input and
/// the preview survive every failure so the user can retry.
@MainActor
final class GroupJoinModel: ObservableObject {
    @Published var codeText: String
    @Published private(set) var preview: InvitePreviewResponse?
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    private let groups: GroupsController

    init(groups: GroupsController, code: InviteCode?) {
        self.groups = groups
        self.codeText = code?.grouped ?? ""
    }

    var code: InviteCode? { InviteCode(normalizing: codeText) }

    /// Loads what the code points at.
    func loadPreview() async {
        guard let code else {
            message = String(localized: "초대 코드는 12자예요. 다시 확인해 주세요.")
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            preview = try await groups.previewInvite(code)
            message = nil
        } catch {
            preview = nil
            message = GroupMessages.joinText(for: GroupsController.normalize(error))
        }
    }

    /// Joins the previewed group. Returns its ID on success; nil when the subscription screen
    /// took over or the join failed (with `message` set).
    func accept() async -> UUID? {
        guard let preview, let code else { return nil }
        if preview.alreadyMember { return preview.groupId }
        if preview.requiresSubscription, !groups.isEntitled {
            groups.requestSubscription()
            return nil
        }
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let detail = try await groups.joinGroup(code: code)
            message = nil
            return detail.id
        } catch {
            message = GroupMessages.joinText(for: GroupsController.normalize(error))
            return nil
        }
    }

    /// A different code than the one previewed drops the old preview.
    func codeDidChange() {
        if let preview, InviteCode(normalizing: preview.code) != code {
            self.preview = nil
        }
        message = nil
    }
}

/// The group settings screen: the group's detail, members and bans, notification switches,
/// and the admin actions.
@MainActor
final class GroupSettingsModel: ObservableObject {
    @Published private(set) var detail: GroupDetail?
    @Published private(set) var members: [MemberResponse] = []
    @Published private(set) var bans: [BanResponse] = []
    @Published private(set) var hasMoreMembers = false
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published var message: String?
    @Published var nameText = ""
    @Published private(set) var notifications = GroupNotificationSettings()

    let groupID: UUID
    private let groups: GroupsController
    private var nextMembersCursor: String?

    init(groups: GroupsController, groupID: UUID) {
        self.groups = groups
        self.groupID = groupID
        if let summary = groups.group(groupID) {
            nameText = summary.name
            notifications = summary.notifications
        }
    }

    /// The freshest view of the group: the loaded detail, else the sidebar summary.
    var summary: GroupSummary? { detail?.summary ?? groups.group(groupID) }

    var capabilities: GroupAdminCapabilities? { summary.map(GroupAdminCapabilities.init) }

    var leavePlan: GroupLeavePlan? { summary.map(GroupLeavePlan.init) }

    /// Members other than me, for picking a new admin.
    var otherMembers: [MemberResponse] {
        members.filter { $0.user.id != groups.me?.id }
    }

    func isMe(_ user: UserSummary) -> Bool { user.id == groups.me?.id }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let detail = try await groups.groupDetail(groupID)
            apply(detail)
            let page = try await groups.api.members(
                groupID: groupID, cursor: nil, limit: Page<MemberResponse>.maximumLimit)
            members = page.items
            nextMembersCursor = page.nextCursor
            hasMoreMembers = page.nextCursor != nil
            if GroupAdminCapabilities(group: detail.summary).canManageBans {
                bans = try await groups.api.bans(groupID: groupID)
            } else {
                bans = []
            }
            message = nil
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
        }
    }

    func loadMoreMembers() async {
        guard let cursor = nextMembersCursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await groups.api.members(
                groupID: groupID, cursor: cursor, limit: Page<MemberResponse>.maximumLimit)
            members.append(contentsOf: page.items)
            nextMembersCursor = page.nextCursor
            hasMoreMembers = page.nextCursor != nil
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
        }
    }

    var canSaveName: Bool {
        GroupNameRules.isValidGroupName(nameText)
            && GroupNameRules.normalized(nameText) != summary?.name
    }

    func saveName() async {
        guard canSaveName else { return }
        await run { [self] in
            apply(try await groups.renameGroup(groupID, to: GroupNameRules.normalized(nameText)))
        }
    }

    /// Saves a switch right away; on failure the switch flips back.
    func setNotifications(_ settings: GroupNotificationSettings) async {
        let previous = notifications
        notifications = settings
        do {
            try await groups.updateNotifications(groupID, settings)
            message = nil
        } catch {
            notifications = previous
            message = GroupMessages.text(for: groups.handle(error))
        }
    }

    /// Removes and bans a member (강퇴).
    func remove(_ member: MemberResponse) async {
        await run { [self] in
            try await groups.removeMember(member.user.id, from: groupID)
            members.removeAll { $0.user.id == member.user.id }
            bans = (try? await groups.api.bans(groupID: groupID)) ?? bans
        }
    }

    func unban(_ ban: BanResponse) async {
        await run { [self] in
            try await groups.unban(ban.user.id, in: groupID)
            bans.removeAll { $0.user.id == ban.user.id }
        }
    }

    func transferAdmin(to member: MemberResponse) async {
        await run { [self] in
            apply(try await groups.transferAdmin(groupID, to: member.user.id))
            members = members.map {
                MemberResponse(
                    user: $0.user, isAdmin: $0.user.id == member.user.id, joinedAt: $0.joinedAt)
            }
        }
    }

    /// Hands the group to `member`, then leaves as an ordinary member. Returns whether I left.
    func transferAndLeave(to member: MemberResponse) async -> Bool {
        await runReturning { [self] in
            apply(try await groups.transferAdmin(groupID, to: member.user.id))
            try await groups.leaveGroup(groupID)
        }
    }

    /// Leaves (an admin leaving this way opens the vote). Returns whether I left.
    func leave() async -> Bool {
        await runReturning { [self] in try await groups.leaveGroup(groupID) }
    }

    /// Schedules the deletion (7-day grace). Returns whether it was scheduled.
    func deleteGroup() async -> Bool {
        await runReturning { [self] in
            try await groups.deleteGroup(groupID)
            if let detail = try? await groups.groupDetail(groupID) { apply(detail) }
        }
    }

    private func apply(_ detail: GroupDetail) {
        self.detail = detail
        nameText = detail.name
        notifications = detail.notifications
    }

    private func run(_ work: @MainActor () async throws -> Void) async {
        _ = await runReturning(work)
    }

    private func runReturning(_ work: @MainActor () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            message = nil
            return true
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
            return false
        }
    }
}

/// The invite screen: live invites, making one with a member limit, revoking.
@MainActor
final class GroupInviteModel: ObservableObject {
    @Published private(set) var invites: [InviteResponse] = []
    @Published private(set) var created: InviteResponse?
    @Published var maxUses = GroupInviteRules.defaultMaxUses
    @Published private(set) var isWorking = false
    @Published var message: String?

    let groupID: UUID
    private let groups: GroupsController
    /// Reused until a create succeeds, so a retry after a lost response makes one invite.
    private var pendingClientID = UUID()

    init(groups: GroupsController, groupID: UUID) {
        self.groups = groups
        self.groupID = groupID
    }

    var capabilities: GroupAdminCapabilities? {
        groups.group(groupID).map(GroupAdminCapabilities.init)
    }

    func load() async {
        do {
            invites = try await groups.api.invites(groupID: groupID)
            message = nil
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
        }
    }

    func create() async {
        guard GroupInviteRules.isValid(maxUses: maxUses) else {
            message = String(localized: "인원은 1명부터 100명까지 정할 수 있어요.")
            return
        }
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let invite = try await groups.createInvite(
                in: groupID, maxUses: maxUses, clientID: pendingClientID)
            pendingClientID = UUID()
            created = invite
            invites.removeAll { $0.code == invite.code }
            invites.insert(invite, at: 0)
            message = nil
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
        }
    }

    func revoke(_ invite: InviteResponse) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await groups.api.revokeInvite(groupID: groupID, code: invite.code)
            invites.removeAll { $0.code == invite.code }
            if created?.code == invite.code { created = nil }
            message = nil
        } catch {
            message = GroupMessages.text(for: groups.handle(error))
        }
    }
}

/// The admin election ballot: candidates, my choice (changeable until it closes) and turnout.
/// Vote counts are secret until the round closes, so only turnout is shown.
@MainActor
final class GroupVoteModel: ObservableObject {
    @Published private(set) var vote: VoteResponse?
    @Published var selection: UUID?
    @Published private(set) var isWorking = false
    @Published private(set) var isClosed = false
    @Published var message: String?

    let groupID: UUID
    private let groups: GroupsController

    init(groups: GroupsController, groupID: UUID) {
        self.groups = groups
        self.groupID = groupID
    }

    var isRunoff: Bool { (vote?.round ?? 1) > 1 }

    /// Whether the button casts a first ballot or changes one.
    var isChangingBallot: Bool { vote?.myBallot != nil }

    var canCast: Bool {
        guard let vote, let selection, !isClosed else { return false }
        return selection != vote.myBallot && vote.candidates.contains { $0.id == selection }
    }

    func isMe(_ user: UserSummary) -> Bool { user.id == groups.me?.id }

    func load() async {
        do {
            let vote = try await groups.api.vote(groupID: groupID)
            self.vote = vote
            selection = selection ?? vote.myBallot
            isClosed = false
            message = nil
        } catch {
            let error = groups.handle(error)
            if error.code == .notFound || error.code == .voteNotOpen {
                isClosed = true
                vote = nil
                await groups.refresh()
            } else {
                message = GroupMessages.text(for: error)
            }
        }
    }

    func cast() async {
        guard canCast, let selection, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            vote = try await groups.castBallot(in: groupID, for: selection)
            message = nil
        } catch {
            let error = groups.handle(error)
            if error.code == .voteNotOpen {
                isClosed = true
                await groups.refresh()
            }
            message = GroupMessages.text(for: error)
        }
    }
}
