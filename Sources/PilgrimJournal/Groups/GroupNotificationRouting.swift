import Foundation
import PilgrimAPI

#if canImport(UserNotifications)
import UserNotifications
#endif

/// The screen a tapped group notification opens (design.md 10절: `pilgrim.kind` decides).
enum GroupNotificationRoute: Equatable, Sendable {
    /// A new post: its detail inside its group.
    case post(groupID: UUID, postID: UUID)
    /// Admin-vote and deletion notices, or a new-post notice without a post ID.
    case group(UUID)
    case dailyReport
}

extension GroupNotificationRoute {
    init?(info: PushPayload.Info) {
        switch info.kind {
        case .newPost:
            guard let groupID = info.groupId else { return nil }
            if let postID = info.postId {
                self = .post(groupID: groupID, postID: postID)
            } else {
                self = .group(groupID)
            }
        case .dailyReport:
            self = .dailyReport
        case .voteStarted, .voteRunoff, .voteDecided, .groupDeletionScheduled:
            guard let groupID = info.groupId else { return nil }
            self = .group(groupID)
        }
    }

    /// The route in a notification's `userInfo` (the APNs payload), or nil when it is not a
    /// group notification this app version understands.
    init?(userInfo: [AnyHashable: Any]) {
        guard let pilgrim = userInfo["pilgrim"] as? [String: Any],
            JSONSerialization.isValidJSONObject(pilgrim),
            let data = try? JSONSerialization.data(withJSONObject: pilgrim),
            let info = try? PilgrimJSON.decode(PushPayload.Info.self, from: data)
        else { return nil }
        self.init(info: info)
    }
}

/// Where the app and scene delegates hand APNs registration results and notification taps.
///
/// Taps can arrive before the journal is open (cold launch, locked, signed out), so routes wait
/// here until a `GroupsController` drains them. The device token is kept for the device
/// registration that A7 adds; nothing here asks for notification permission or registers for
/// remote notifications. While groups are off nothing is accepted.
@MainActor
final class GroupNotificationRouting {
    static let shared = GroupNotificationRouting(isEnabled: GroupsFeature.isEnabled)

    let isEnabled: Bool
    private(set) var deviceToken: Data?
    private(set) var registrationFailureDescription: String?
    private var waitingRoutes: [GroupNotificationRoute] = []
    /// Called after APNs hands out a (new) device token.
    var onDeviceToken: ((Data) -> Void)?
    /// Called after a route is queued.
    var onRoute: (() -> Void)?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    var hasWaitingRoutes: Bool { !waitingRoutes.isEmpty }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard isEnabled else { return }
        registrationFailureDescription = nil
        guard deviceToken != self.deviceToken else { return }
        self.deviceToken = deviceToken
        onDeviceToken?(deviceToken)
    }

    func didFailToRegisterForRemoteNotifications(_ error: any Error) {
        guard isEnabled else { return }
        registrationFailureDescription = error.localizedDescription
    }

    /// Queues the route of a tapped notification. Returns whether it was a group notification.
    @discardableResult
    func handleTap(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = GroupNotificationRoute(userInfo: userInfo) else { return false }
        return receive(route)
    }

    @discardableResult
    func receive(_ route: GroupNotificationRoute) -> Bool {
        guard isEnabled else { return false }
        waitingRoutes.append(route)
        onRoute?()
        return true
    }

    /// Hands every waiting route to the caller, oldest first, and empties the queue.
    func drainRoutes() -> [GroupNotificationRoute] {
        defer { waitingRoutes = [] }
        return waitingRoutes
    }

    /// The token as the server stores it: lowercase hex.
    static func hexString(deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(UserNotifications)
/// Receives notification taps and foreground deliveries for group notifications. Installed as
/// the notification center's delegate by the app delegate, only while groups are on.
final class GroupNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = GroupNotificationCenterDelegate()

    /// The center keeps its delegate weakly; `shared` keeps this one alive.
    @MainActor
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route =
            response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? GroupNotificationRoute(userInfo: response.notification.request.content.userInfo)
            : nil
        completionHandler()
        guard let route else { return }
        Task { @MainActor in
            GroupNotificationRouting.shared.receive(route)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isGroupNotification =
            GroupNotificationRoute(userInfo: notification.request.content.userInfo) != nil
        completionHandler(isGroupNotification ? [.banner, .list, .sound] : [])
    }
}
#endif
