import Combine
import Foundation
import JournalGroups
import PilgrimAPI

/// The app's side of private groups: the groups this user belongs to, loaded from the group
/// server, plus the invites and notification taps waiting for the group screens. Owned by
/// `AppModel` (built in `JournalSessionController.makeAppModel(for:)`), and only while
/// `GroupsFeature` is on.
///
/// T0.3 stub: A2 adds sign-in, onboarding, create/join and settings on top of this.
@MainActor
final class GroupsController: ObservableObject {
    @Published private(set) var groups: [GroupSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastError: GroupAPIError?
    /// Invite codes received from links or QR codes, oldest first, waiting for the join flow.
    @Published private(set) var pendingInviteCodes: [InviteCode] = []
    /// Placeholders the sidebar opens until A2 brings the real sheets.
    @Published var isPresentingCreateGroup = false
    @Published var isPresentingJoinGroup = false

    let api: any GroupAPI
    /// Called with each tapped group notification once this controller is attached.
    var onOpenRoute: ((GroupNotificationRoute) -> Void)?

    private let invites: PendingGroupInvite
    private let notifications: GroupNotificationRouting

    init(
        api: any GroupAPI,
        invites: PendingGroupInvite = .shared,
        notifications: GroupNotificationRouting = .shared
    ) {
        self.api = api
        self.invites = invites
        self.notifications = notifications
    }

    func group(_ id: UUID) -> GroupSummary? {
        groups.first { $0.id == id }
    }

    var totalUnreadCount: Int {
        groups.reduce(0) { $0 + $1.unreadCount }
    }

    var errorMessage: String? {
        guard let lastError else { return nil }
        switch lastError {
        case .offline, .timedOut:
            return String(localized: "그룹 서버에 연결할 수 없어요.")
        case .notSignedIn:
            return String(localized: "그룹에 로그인해 주세요.")
        default:
            return String(localized: "그룹을 불러오지 못했어요.")
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
        } catch let error as GroupAPIError {
            if error != .cancelled { lastError = error }
        } catch is CancellationError {
            return
        } catch {
            lastError = .invalidResponse(status: 0)
        }
        hasLoaded = true
    }

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

    private func takePendingInvites() {
        for code in invites.drain() where !pendingInviteCodes.contains(code) {
            pendingInviteCodes.append(code)
        }
    }

    private func takePendingRoutes() {
        guard let onOpenRoute else { return }
        for route in notifications.drainRoutes() {
            onOpenRoute(route)
        }
    }
}
