import AuthenticationServices
import Combine
import Foundation
import JournalData
import JournalGroups
import PilgrimAPI

/// The app's side of private groups: whether this user is signed in to the group server, the
/// groups they belong to, and the invites and notification taps waiting for the group screens.
/// Owned by `AppModel` (built in `JournalSessionController.makeAppModel(for:)`), and only while
/// `GroupsFeature` is on.
///
/// The group session itself (tokens, refresh) lives in the `GroupAPI` client; this controller
/// learns where the user stands from `GET /me` and the sign-in response, and keeps
/// `accountState` in step with every call (a lost session sends the user back to
/// "그룹 시작하기", a 426 to the update notice). A failure never touches the journal.
@MainActor
final class GroupsController: ObservableObject {
    @Published private(set) var groups: [GroupSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastError: GroupAPIError?
    /// Invite codes received from links or QR codes, oldest first, waiting for the join flow.
    @Published private(set) var pendingInviteCodes: [InviteCode] = []
    @Published private(set) var accountState: GroupsAccountState = .unknown
    /// The signed-in group profile.
    @Published private(set) var me: MeResponse?
    @Published private(set) var isSigningIn = false
    /// Why the last sign-in failed (nil after a cancel).
    @Published var signInMessage: String?
    /// The group sheet on screen, hosted by `groupsSheets(_:)`.
    @Published var presentedSheet: GroupsSheet?

    let api: any GroupAPI
    /// Called with each tapped group notification once this controller is attached.
    var onOpenRoute: ((GroupNotificationRoute) -> Void)?
    /// Opens the subscription screen (A8). Until it is set, a placeholder sheet stands in.
    var onSubscriptionRequired: (() -> Void)?

    private let invites: PendingGroupInvite
    private let notifications: GroupNotificationRouting
    private let authorizer: any GroupAppleAuthorizing
    private let credentials: any GroupSecureItemStoring
    private let journalAppleUserIdentifier: @MainActor () async -> String?
    private let developmentAppleUser: String?
    private let bundleID: String
    /// The nonce of a Sign in with Apple button request in flight.
    private var pendingButtonNonce: GroupAppleNonce?

    init(
        api: any GroupAPI,
        invites: PendingGroupInvite = .shared,
        notifications: GroupNotificationRouting = .shared,
        authorizer: (any GroupAppleAuthorizing)? = nil,
        credentials: any GroupSecureItemStoring = GroupCredentialStore(),
        journalAppleUserIdentifier: @escaping @MainActor () async -> String? =
            GroupsController.storedJournalAppleUserIdentifier,
        developmentAppleUser: String? = GroupsController.defaultDevelopmentAppleUser,
        bundleID: String = GroupsController.defaultBundleID
    ) {
        self.api = api
        self.invites = invites
        self.notifications = notifications
        self.authorizer = authorizer ?? GroupAppleAuthorizer()
        self.credentials = credentials
        self.journalAppleUserIdentifier = journalAppleUserIdentifier
        self.developmentAppleUser = developmentAppleUser
        self.bundleID = bundleID
    }

    func group(_ id: UUID) -> GroupSummary? {
        groups.first { $0.id == id }
    }

    var totalUnreadCount: Int {
        groups.reduce(0) { $0 + $1.unreadCount }
    }

    /// Whether the server lets this user into group features without (another) purchase.
    var isEntitled: Bool {
        guard let entitlement = me?.entitlement else { return true }
        return !entitlement.subscriptionRequired || entitlement.active
    }

    /// Whether Debug's development sign-in (`PILGRIM_DEV_APPLE_USER`) replaces Apple.
    var usesDevelopmentSignIn: Bool { developmentAppleUser != nil }

    var errorMessage: String? {
        guard let lastError else { return nil }
        switch lastError {
        case .offline, .timedOut:
            return String(localized: "그룹 서버에 연결할 수 없어요.")
        case .notSignedIn:
            return String(localized: "그룹에 로그인해 주세요.")
        default:
            if lastError.code == .clientUpgradeRequired { return GroupMessages.upgradeRequired }
            return String(localized: "그룹을 불러오지 못했어요.")
        }
    }

    // MARK: Account

    /// Finds out where the user stands and loads the groups. Called when the 그룹 section
    /// appears; also the retry of the connection notice.
    func start() async {
        await loadAccount()
        if accountState.hasGroupAccess {
            await refresh()
        }
        presentPendingInviteIfReady()
    }

    /// `GET /me`. Offline keeps the last known state and shows the connection notice.
    func loadAccount() async {
        do {
            apply(try await api.me())
            lastError = nil
        } catch {
            let error = handle(error)
            // Signed out and too old are states of their own, not a connection notice.
            guard !error.requiresGroupSignIn, error.code != .clientUpgradeRequired,
                error != .cancelled
            else { return }
            lastError = error
        }
    }

    /// Reloads the group list. A failure keeps the last list on screen.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            groups = try await api.groups()
            lastError = nil
        } catch {
            let error = handle(error)
            if error != .cancelled { lastError = error }
        }
        hasLoaded = true
    }

    /// Re-authenticates with Apple through `GroupAppleAuthorizing` and signs in to the group
    /// server. Returns whether the session started.
    @discardableResult
    func signInWithApple() async -> Bool {
        guard !isSigningIn else { return false }
        isSigningIn = true
        defer { isSigningIn = false }
        signInMessage = nil
        do {
            if let developmentAppleUser {
                return try await finishSignIn(
                    api.signInForDevelopment(
                        DevSignInRequest(
                            devUser: developmentAppleUser, bundleId: bundleID,
                            installationId: credentials.installationID())))
            }
            let journalUser = await journalAppleUserIdentifier()
            let nonce = GroupAppleNonce.make()
            let credential = try await authorizer.requestCredential(hashedNonce: nonce.hashed)
            return try await submit(credential, nonce: nonce, journalUser: journalUser)
        } catch {
            reportSignInFailure(error)
            return false
        }
    }

    /// The nonce for a `SignInWithAppleButton` request; pass the result back to
    /// `finishAppleButtonSignIn`.
    func prepareAppleButtonRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = GroupAppleNonce.make()
        pendingButtonNonce = nonce
        signInMessage = nil
        GroupAppleAuthorizer.configure(request, hashedNonce: nonce.hashed)
    }

    /// Completes a `SignInWithAppleButton` sign-in.
    @discardableResult
    func finishAppleButtonSignIn(_ result: Result<ASAuthorization, any Error>) async -> Bool {
        guard let nonce = pendingButtonNonce, !isSigningIn else { return false }
        pendingButtonNonce = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let credential = try GroupAppleAuthorizer.credential(from: result)
            let journalUser = await journalAppleUserIdentifier()
            return try await submit(credential, nonce: nonce, journalUser: journalUser)
        } catch {
            reportSignInFailure(error)
            return false
        }
    }

    /// Saves the sign-up screen: the name, an optional photo (already prepared by
    /// `GroupProfilePhotoPreparer`), and the device time zone. Throws `GroupAPIError`; the
    /// sheet keeps its input for a retry, and the photo's `clientID` makes the retry reuse
    /// the upload.
    func completeProfile(
        displayName: String, photo: PreparedGroupPhoto?, timeZone: TimeZone = .current
    ) async throws {
        let name = GroupNameRules.normalized(displayName)
        guard APILimits.isValidDisplayName(name) else {
            throw GroupAPIError.server(.validationFailed, field: "displayName")
        }
        let me = try await perform {
            var photoID: UUID?
            if let photo {
                photoID = try await self.api.upload(
                    GroupMediaUpload(
                        clientID: photo.clientID, purpose: .profile, groupID: nil,
                        jpegData: photo.jpegData, width: photo.width, height: photo.height)
                ).id
            }
            return try await self.api.updateMe(
                UpdateMeRequest(
                    displayName: name, profilePhotoId: photoID, timeZone: timeZone.identifier))
        }
        apply(me)
        await afterAccess()
    }

    /// Opens the subscription screen (A8) or its placeholder.
    func requestSubscription() {
        if let onSubscriptionRequired {
            presentedSheet = nil
            onSubscriptionRequired()
        } else {
            presentedSheet = .subscription
        }
    }

    // MARK: Groups

    func createGroup(named name: String, clientID: UUID) async throws -> GroupDetail {
        let detail = try await perform {
            try await self.api.createGroup(
                CreateGroupRequest(clientId: clientID, name: GroupNameRules.normalized(name)))
        }
        upsert(detail.summary)
        await refresh()
        return detail
    }

    func previewInvite(_ code: InviteCode) async throws -> InvitePreviewResponse {
        try await perform { try await self.api.invitePreview(code: code.rawValue) }
    }

    func joinGroup(code: InviteCode) async throws -> GroupDetail {
        let detail = try await perform { try await self.api.acceptInvite(code: code.rawValue) }
        upsert(detail.summary)
        await refresh()
        return detail
    }

    func groupDetail(_ id: UUID) async throws -> GroupDetail {
        let detail = try await perform(groupID: id) { try await self.api.group(id: id) }
        upsert(detail.summary)
        return detail
    }

    func renameGroup(_ id: UUID, to name: String) async throws -> GroupDetail {
        let detail = try await perform(groupID: id) {
            try await self.api.updateGroup(id: id, UpdateGroupRequest(name: name))
        }
        upsert(detail.summary)
        return detail
    }

    func leaveGroup(_ id: UUID) async throws {
        try await perform(groupID: id) { try await self.api.leaveGroup(id: id) }
        groups.removeAll { $0.id == id }
        await refresh()
    }

    /// Admin: schedules the deletion (7-day grace, read and scrap only).
    func deleteGroup(_ id: UUID) async throws {
        try await perform(groupID: id) { try await self.api.deleteGroup(id: id) }
        await refresh()
    }

    func removeMember(_ userID: UUID, from groupID: UUID) async throws {
        try await perform(groupID: groupID) {
            try await self.api.removeMember(groupID: groupID, userID: userID)
        }
        await refresh()
    }

    func unban(_ userID: UUID, in groupID: UUID) async throws {
        try await perform(groupID: groupID) {
            try await self.api.unban(groupID: groupID, userID: userID)
        }
    }

    func transferAdmin(_ groupID: UUID, to userID: UUID) async throws -> GroupDetail {
        let detail = try await perform(groupID: groupID) {
            try await self.api.transferAdmin(
                groupID: groupID, TransferAdminRequest(userId: userID))
        }
        upsert(detail.summary)
        return detail
    }

    func updateNotifications(_ groupID: UUID, _ settings: GroupNotificationSettings)
        async throws
    {
        try await perform(groupID: groupID) {
            try await self.api.updateNotifications(groupID: groupID, settings)
        }
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].notifications = settings
        }
    }

    func createInvite(in groupID: UUID, maxUses: Int, clientID: UUID) async throws
        -> InviteResponse
    {
        guard GroupInviteRules.isValid(maxUses: maxUses) else {
            throw GroupAPIError.server(.limitExceeded, field: "maxUses")
        }
        return try await perform(groupID: groupID) {
            try await self.api.createInvite(
                groupID: groupID, CreateInviteRequest(clientId: clientID, maxUses: maxUses))
        }
    }

    func castBallot(in groupID: UUID, for candidateID: UUID) async throws -> VoteResponse {
        try await perform(groupID: groupID) {
            try await self.api.castBallot(
                groupID: groupID, CastBallotRequest(candidateUserId: candidateID))
        }
    }

    // MARK: Sheets and queued events

    /// Starts taking invites and notification taps from the app-wide queues. Called for the
    /// model the session actually shows, so a model built and dropped during scope migration
    /// never swallows them.
    func attachToSystemEvents() {
        invites.onReceive = { [weak self] in self?.takePendingInvites() }
        notifications.onRoute = { [weak self] in self?.takePendingRoutes() }
        takePendingInvites()
        takePendingRoutes()
    }

    /// Hands the oldest waiting invite to the join flow and removes it from the queue.
    func takeNextPendingInvite() -> InviteCode? {
        guard !pendingInviteCodes.isEmpty else { return nil }
        return pendingInviteCodes.removeFirst()
    }

    /// Opens what the user tapped in the sidebar: the join sheet once groups are usable, the
    /// onboarding sheet before.
    func beginJoin(code: InviteCode? = nil) {
        if accountState.needsOnboarding {
            if let code, !pendingInviteCodes.contains(code) { pendingInviteCodes.append(code) }
            presentedSheet = .onboarding
        } else {
            presentedSheet = .join(GroupJoinRequest(code: code))
        }
    }

    func beginOnboarding() {
        presentedSheet = .onboarding
    }

    func beginCreateGroup() {
        if accountState.needsOnboarding {
            presentedSheet = .onboarding
        } else if !isEntitled {
            requestSubscription()
        } else {
            presentedSheet = .createGroup
        }
    }

    /// Called when a group sheet goes away; shows the next waiting invite, if any.
    func sheetDidDismiss() {
        presentPendingInviteIfReady()
    }

    /// Shows the oldest waiting invite when nothing else is on screen: the join sheet once the
    /// user can see groups, the onboarding sheet while they still have to sign in or sign up
    /// (the invite stays queued until that is done). Waits while the state is unknown.
    func presentPendingInviteIfReady() {
        guard presentedSheet == nil || presentedSheet == .onboarding,
            !pendingInviteCodes.isEmpty
        else { return }
        switch accountState {
        case .signedIn, .needsSubscription:
            guard let code = takeNextPendingInvite() else { return }
            presentedSheet = .join(GroupJoinRequest(code: code))
        case .signedOut, .needsProfile:
            presentedSheet = .onboarding
        case .unknown, .upgradeRequired:
            break
        }
    }

    // MARK: Errors

    /// Turns any thrown error into a `GroupAPIError` and keeps `accountState` in step: a lost
    /// group session signs the user out of groups only, a 426 shows the update notice, and a
    /// missing sign-up sends them back to the sign-up screen.
    @discardableResult
    func handle(_ error: any Error) -> GroupAPIError {
        let error = Self.normalize(error)
        if error.requiresGroupSignIn {
            signOutLocally()
        } else if error.code == .clientUpgradeRequired {
            accountState = .upgradeRequired
        } else if error.code == .signupRequired {
            accountState = .needsProfile
        } else if error.code == .subscriptionRequired, accountState == .signedIn {
            accountState = .needsSubscription
        }
        return error
    }

    nonisolated static func normalize(_ error: any Error) -> GroupAPIError {
        if let error = error as? GroupAPIError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .offline
            }
        }
        return .invalidResponse(status: 0)
    }

    // MARK: Defaults

    /// The Apple user the journal session is signed in as.
    static func storedJournalAppleUserIdentifier() async -> String? {
        try? await AppleAuthenticationSessionService().session().currentUserIdentifier
    }

    /// Debug builds launched with `PILGRIM_DEV_APPLE_USER` sign in with `POST /auth/dev`.
    nonisolated static var defaultDevelopmentAppleUser: String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["PILGRIM_DEV_APPLE_USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }

    /// This app's bundle ID when it is one the server accepts, else the build's default (the
    /// SwiftPM test host has its own).
    nonisolated static var defaultBundleID: String {
        if let identifier = Bundle.main.bundleIdentifier, BundleIDs.all.contains(identifier) {
            return identifier
        }
        return GroupsFeature.isDebugBuild ? BundleIDs.debug : BundleIDs.release
    }

    // MARK: Private

    private func submit(
        _ credential: GroupAppleCredential, nonce: GroupAppleNonce, journalUser: String?
    ) async throws -> Bool {
        // Rejected before anything reaches the server.
        let proof = try GroupAppleAuthorization.verify(
            credential, journalUserIdentifier: journalUser, nonce: nonce)
        let request = AppleSignInRequest(
            identityToken: proof.identityToken, authorizationCode: proof.authorizationCode,
            rawNonce: proof.rawNonce, bundleId: bundleID,
            installationId: try credentials.installationID())
        return try await finishSignIn(api.signInWithApple(request))
    }

    private func finishSignIn(_ response: AuthSessionResponse) async -> Bool {
        apply(response.user)
        lastError = nil
        await afterAccess()
        return true
    }

    /// After sign-in or sign-up: load the groups, then continue with what was waiting.
    private func afterAccess() async {
        if accountState.hasGroupAccess {
            await refresh()
            if presentedSheet == .onboarding { presentedSheet = nil }
            if accountState == .needsSubscription, pendingInviteCodes.isEmpty {
                requestSubscription()
                return
            }
            presentPendingInviteIfReady()
        }
    }

    private func reportSignInFailure(_ error: any Error) {
        if let error = error as? GroupAppleAuthorizationError {
            signInMessage = error.message
        } else if let error = error as? GroupCredentialStoreError {
            signInMessage = error.message
        } else {
            let error = handle(error)
            signInMessage = error == .cancelled ? nil : GroupMessages.text(for: error)
        }
    }

    private func apply(_ me: MeResponse) {
        self.me = me
        accountState = GroupsAccountState(me: me)
    }

    private func signOutLocally() {
        accountState = .signedOut
        me = nil
        groups = []
    }

    private func upsert(_ summary: GroupSummary) {
        if let index = groups.firstIndex(where: { $0.id == summary.id }) {
            groups[index] = summary
        } else {
            groups.insert(summary, at: 0)
        }
    }

    private func perform<T: Sendable>(_ work: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw handle(error)
        }
    }

    /// A group call: a group the server no longer shows me (removed, deleted) leaves the list.
    private func perform<T: Sendable>(
        groupID: UUID, _ work: @MainActor () async throws -> T
    ) async throws -> T {
        do {
            return try await work()
        } catch {
            let error = handle(error)
            if error.code == .notFound || error.code == .removedFromGroup {
                groups.removeAll { $0.id == groupID }
            }
            throw error
        }
    }

    private func takePendingInvites() {
        for code in invites.drain() where !pendingInviteCodes.contains(code) {
            pendingInviteCodes.append(code)
        }
        presentPendingInviteIfReady()
    }

    private func takePendingRoutes() {
        guard let onOpenRoute else { return }
        for route in notifications.drainRoutes() {
            onOpenRoute(route)
        }
    }
}
