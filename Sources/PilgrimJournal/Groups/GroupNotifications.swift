import Combine
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

#if canImport(UserNotifications)
import UserNotifications
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Group notifications on the app side (design.md 10절, tasks 2.7.1–2.7.2):
//
// - `GroupNotificationRegistrar` asks for permission once the user first belongs to a group on
//   this device (right after the first create or join), registers with APNs, and keeps
//   `PUT /me/devices/:installationId` current (token, APNs environment, bundle, time zone).
// - `GroupNotificationOpener` opens a tapped notification's post, Daily Report or group, but
//   only once the app lock is unlocked, and says so when the group is no longer the user's.
//
// The pure decisions (`GroupNotificationPermissionPolicy`, `GroupDeviceRegistration`,
// `GroupNotificationRouteGate`, `GroupNotificationDestination`) carry the rules and are unit
// tested; the classes only wire them to the system. Everything is inert while `GroupsFeature`
// is off.
//
// Phase 2 hooks (files this track does not own):
// 1. `JournalSessionController.makeAppModel(for:)`: route taps through the opener —
//    `groups.onOpenRoute = { route in GroupNotificationOpener.shared.receive(route) }`.
// 2. `PilgrimJournalApp.prepareJournalSession()`, right after `await appLock.bootstrap()`:
//    `GroupNotificationOpener.shared.appLockDidBootstrap(appLock)`.
// 3. `ContentView.body`: `.groupNotificationHandling(preferredCompactColumn:
//    $preferredCompactColumn)` (attaches the destination, starts the registrar, hosts the
//    Daily Report sheet and the "no longer available" alert).

// MARK: - Permission

/// The system's notification permission, as group notifications need it.
enum GroupNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    /// Quiet delivery without a prompt (provisional or ephemeral); APNs still delivers.
    case provisional

    var allowsRemoteNotifications: Bool {
        self == .authorized || self == .provisional
    }
}

#if canImport(UserNotifications)
extension GroupNotificationAuthorization {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .provisional: self = .provisional
        case .notDetermined: self = .notDetermined
        #if os(iOS)
        case .ephemeral: self = .provisional
        #endif
        @unknown default: self = .denied
        }
    }
}
#endif

/// When to show the system notification prompt (design.md 10절: "권한은 처음 그룹을 만들거나
/// 들어갈 때 묻는다").
enum GroupNotificationPermissionPolicy {
    /// Ask only while the system has not asked yet, only once per installation, and only once
    /// the user belongs to a group. The first create or join is the moment the group count
    /// leaves zero; a user who already belongs to groups from another device is asked the first
    /// time this device sees them signed in.
    static func shouldRequestAuthorization(
        status: GroupNotificationAuthorization, hasAskedOnThisDevice: Bool, groupCount: Int
    ) -> Bool {
        status == .notDetermined && !hasAskedOnThisDevice && groupCount > 0
    }

    /// Whether to ask APNs for a device token: the user allowed notifications and belongs to a
    /// group. Asked again on every launch, as Apple recommends (tokens can change).
    static func shouldRegisterForRemoteNotifications(
        status: GroupNotificationAuthorization, groupCount: Int
    ) -> Bool {
        status.allowsRemoteNotifications && groupCount > 0
    }
}

// MARK: - Device registration

/// Builds `PUT /me/devices/:installationId` bodies.
enum GroupDeviceRegistration {
    /// What to send as `apnsToken` now.
    enum TokenDecision: Equatable, Sendable {
        /// Send this (hex token, or nil to tell the server not to push to this device).
        case send(String?)
        /// Allowed, but APNs has not handed out a token yet: wait for it rather than clearing
        /// the token the server already has.
        case wait
    }

    static func tokenDecision(status: GroupNotificationAuthorization, deviceToken: Data?)
        -> TokenDecision
    {
        guard status.allowsRemoteNotifications else { return .send(nil) }
        guard let deviceToken, !deviceToken.isEmpty else { return .wait }
        // Lowercase hex, as `GroupNotificationRouting.hexString` and the server store it.
        return .send(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Debug builds are signed with the development `aps-environment` (APNs sandbox);
    /// TestFlight and App Store builds (Release) use production.
    static func apnsEnvironment(isDebugBuild: Bool) -> APNSEnvironment {
        isDebugBuild ? .sandbox : .production
    }

    /// `"1.2.0 (45)"` from the bundle, or `"0"` when it has no version (command-line tests).
    static func appVersion(bundle: Bundle = .main) -> String {
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (
            marketing?.isEmpty == false ? marketing : nil, build?.isEmpty == false ? build : nil
        ) {
        case let (marketing?, build?): return "\(marketing) (\(build))"
        case let (marketing?, nil): return marketing
        case let (nil, build?): return build
        case (nil, nil): return "0"
        }
    }

    static func request(
        apnsToken: String?, isDebugBuild: Bool, bundleID: String,
        platform: ClientPlatform = .currentPlatform, locale: Locale, timeZone: TimeZone,
        appVersion: String
    ) -> DeviceRegistrationRequest {
        DeviceRegistrationRequest(
            apnsToken: apnsToken, apnsEnvironment: apnsEnvironment(isDebugBuild: isDebugBuild),
            bundleId: bundleID, platform: platform, locale: locale.identifier(.bcp47),
            timeZone: timeZone.identifier, appVersion: appVersion)
    }
}

/// The system calls the registrar needs; `SystemGroupNotificationCenter` in the app, a fake in
/// tests (the real notification center is not available to command-line tests).
@MainActor
protocol GroupNotificationCenter: AnyObject {
    func authorizationStatus() async -> GroupNotificationAuthorization
    /// Shows the system prompt (alert, sound, badge). Returns whether the user allowed it.
    func requestAuthorization() async -> Bool
    /// Asks APNs for a token; it arrives through the app delegate and
    /// `GroupNotificationRouting.didRegisterForRemoteNotifications`.
    func registerForRemoteNotifications()
}

@MainActor
final class SystemGroupNotificationCenter: GroupNotificationCenter {
    static let shared = SystemGroupNotificationCenter()

    func authorizationStatus() async -> GroupNotificationAuthorization {
        await Self.currentStatus()
    }

    func requestAuthorization() async -> Bool {
        await Self.requestAlertSoundBadge()
    }

    func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Where the system lets the user turn notifications back on.
    static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #endif
    }

    nonisolated private static func currentStatus() async -> GroupNotificationAuthorization {
        #if canImport(UserNotifications)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return GroupNotificationAuthorization(settings.authorizationStatus)
        #else
        return .denied
        #endif
    }

    nonisolated private static func requestAlertSoundBadge() async -> Bool {
        #if canImport(UserNotifications)
        // Badges stay at 0 (design.md 10절), but the design asks for the full set.
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound, .badge,
        ])) ?? false
        #else
        false
        #endif
    }
}

/// Keeps one group session's notification permission and device registration in step with
/// the user's groups: asks for permission when the user first belongs to a group on this
/// device, asks APNs for a token whenever notifications are allowed, and sends
/// `PUT /me/devices/:installationId` when the token, permission, time zone or locale changes.
///
/// Created per `GroupsController` by `GroupNotificationOpener.attach(model:)`; it watches the
/// controller's account state and groups, the APNs token, time-zone changes and the app
/// becoming active (the user may have changed the permission in system settings).
@MainActor
final class GroupNotificationRegistrar {
    static let askedDefaultsKey = "groups.notifications.askedPermission"

    private(set) weak var groups: GroupsController?
    /// The permission seen by the last sync.
    private(set) var authorization: GroupNotificationAuthorization?
    /// The body the server has for this installation in this session.
    private(set) var lastRegistration: DeviceRegistrationRequest?

    private let isEnabled: Bool
    private let center: any GroupNotificationCenter
    private let routing: GroupNotificationRouting
    private let credentials: any GroupSecureItemStoring
    private let defaults: UserDefaults
    private let bundleID: String
    private let isDebugBuild: Bool
    private let appVersion: String
    private let locale: () -> Locale
    private let timeZone: () -> TimeZone
    private let promptDelay: Duration
    private var didAskAPNs = false
    private var needsSync = false
    private var syncTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [any NSObjectProtocol] = []

    init(
        groups: GroupsController,
        isEnabled: Bool = GroupsFeature.isEnabled,
        center: any GroupNotificationCenter = SystemGroupNotificationCenter.shared,
        routing: GroupNotificationRouting = .shared,
        credentials: any GroupSecureItemStoring = GroupCredentialStore(),
        defaults: UserDefaults = .standard,
        bundleID: String = GroupsController.defaultBundleID,
        isDebugBuild: Bool = GroupsFeature.isDebugBuild,
        appVersion: String = GroupDeviceRegistration.appVersion(),
        locale: @escaping () -> Locale = { .current },
        timeZone: @escaping () -> TimeZone = { .current },
        promptDelay: Duration = .milliseconds(700)
    ) {
        self.groups = groups
        self.isEnabled = isEnabled
        self.center = center
        self.routing = routing
        self.credentials = credentials
        self.defaults = defaults
        self.bundleID = bundleID
        self.isDebugBuild = isDebugBuild
        self.appVersion = appVersion
        self.locale = locale
        self.timeZone = timeZone
        self.promptDelay = promptDelay
    }

    var hasAskedOnThisDevice: Bool {
        defaults.bool(forKey: Self.askedDefaultsKey)
    }

    /// Starts watching the controller, the APNs token and the system, and syncs once.
    func start() {
        guard isEnabled, let groups, subscriptions.isEmpty else { return }
        routing.onDeviceToken = { [weak self] _ in self?.scheduleSync() }
        groups.$accountState.removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync() } }
            .store(in: &subscriptions)
        groups.$groups.map(\.count).removeDuplicates()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSync() } }
            .store(in: &subscriptions)
        var names: [Notification.Name] = [
            .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification,
        ]
        #if os(iOS)
        names.append(UIApplication.didBecomeActiveNotification)
        #elseif os(macOS)
        names.append(NSApplication.didBecomeActiveNotification)
        #endif
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSync() }
            }
        }
        scheduleSync()
    }

    func stop() {
        subscriptions = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        syncTask?.cancel()
        syncTask = nil
    }

    /// Coalesces bursts of changes into one sync at a time.
    func scheduleSync() {
        guard isEnabled else { return }
        needsSync = true
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while let self, self.needsSync, !Task.isCancelled {
                self.needsSync = false
                await self.sync()
            }
            self?.syncTask = nil
        }
    }

    /// Waits for the scheduled syncs to finish (tests).
    func waitUntilIdle() async {
        while let task = syncTask { await task.value }
    }

    /// One pass: permission, APNs, device registration.
    func sync() async {
        guard isEnabled, let groups else { return }
        guard groups.accountState.hasGroupAccess else {
            // Logging out removes the device row on the server; the next sign-in sends it again.
            lastRegistration = nil
            return
        }
        let groupCount = groups.groups.count
        var status = await center.authorizationStatus()
        if GroupNotificationPermissionPolicy.shouldRequestAuthorization(
            status: status, hasAskedOnThisDevice: hasAskedOnThisDevice, groupCount: groupCount)
        {
            defaults.set(true, forKey: Self.askedDefaultsKey)
            // Let the create or join sheet go away before the system prompt appears.
            try? await Task.sleep(for: promptDelay)
            _ = await center.requestAuthorization()
            status = await center.authorizationStatus()
        }
        authorization = status
        if GroupNotificationPermissionPolicy.shouldRegisterForRemoteNotifications(
            status: status, groupCount: groupCount), !didAskAPNs
        {
            didAskAPNs = true
            center.registerForRemoteNotifications()
        }
        guard groupCount > 0 else { return }
        guard
            case .send(let token) = GroupDeviceRegistration.tokenDecision(
                status: status, deviceToken: routing.deviceToken)
        else { return }
        let request = GroupDeviceRegistration.request(
            apnsToken: token, isDebugBuild: isDebugBuild, bundleID: bundleID, locale: locale(),
            timeZone: timeZone(), appVersion: appVersion)
        guard request != lastRegistration else { return }
        do {
            try await groups.api.registerDevice(
                installationID: credentials.installationID(), request)
            lastRegistration = request
        } catch {
            // Tried again on the next change or activation.
            groups.handle(error)
        }
    }
}

// MARK: - Opening a tapped notification

/// Holds a tapped notification until it may be opened: the app lock has been read at launch
/// (`isLockSettled`), the journal is unlocked and not behind the privacy shield, and the
/// journal window is there to show it. Only the newest waiting tap is kept; opening older ones
/// first would only flash past them.
struct GroupNotificationRouteGate: Equatable, Sendable {
    struct Conditions: Equatable, Sendable {
        var isLockSettled = false
        var isLocked = false
        var isShielded = false
        var hasDestination = false

        var allowsOpening: Bool { isLockSettled && !isLocked && !isShielded && hasDestination }
    }

    private(set) var conditions = Conditions()
    private(set) var waiting: GroupNotificationRoute?

    /// The route to open now, or nil when it has to wait.
    mutating func receive(_ route: GroupNotificationRoute) -> GroupNotificationRoute? {
        guard conditions.allowsOpening else {
            waiting = route
            return nil
        }
        waiting = nil
        return route
    }

    /// The waiting route, once the new conditions allow opening it.
    mutating func update(_ conditions: Conditions) -> GroupNotificationRoute? {
        self.conditions = conditions
        guard conditions.allowsOpening, let route = waiting else { return nil }
        waiting = nil
        return route
    }

    mutating func discardWaiting() {
        waiting = nil
    }
}

/// What opening a route does, once the user's groups are known.
enum GroupNotificationDestination: Equatable, Sendable {
    case dailyReport
    case group(UUID)
    case post(groupID: UUID, postID: UUID)
    /// The group is no longer one of the user's (left, removed, deleted): show the message and
    /// stay where the user is.
    case unavailable(String)

    static var postGoneMessage: String { GroupContentError.goneMessage }
    static var groupGoneMessage: String { String(localized: "이 그룹은 더 이상 볼 수 없어요") }

    /// `memberGroupIDs` nil means the group list is not known (offline at launch); the route is
    /// then opened as is and the screen shows what the server says. A post that has itself
    /// disappeared (expired, taken down, hidden, blocked) opens its detail, which shows
    /// "이 글은 더 이상 볼 수 없어요".
    static func resolve(_ route: GroupNotificationRoute, memberGroupIDs: Set<UUID>?) -> Self {
        switch route {
        case .dailyReport:
            return .dailyReport
        case .group(let groupID):
            if let memberGroupIDs, !memberGroupIDs.contains(groupID) {
                return .unavailable(groupGoneMessage)
            }
            return .group(groupID)
        case .post(let groupID, let postID):
            if let memberGroupIDs, !memberGroupIDs.contains(groupID) {
                return .unavailable(postGoneMessage)
            }
            return .post(groupID: groupID, postID: postID)
        }
    }

    /// The column an iPhone shows after opening: the feed for a group, the detail for a post.
    var compactColumn: NavigationSplitViewColumn? {
        switch self {
        case .group: .content
        case .post: .detail
        case .dailyReport, .unavailable: nil
        }
    }
}

/// Opens tapped group notifications in the journal window, after the app lock (see
/// `GroupNotificationRouteGate`), and owns the current session's `GroupNotificationRegistrar`.
/// App-wide like the app lock; the journal window attaches itself with
/// `groupNotificationHandling(preferredCompactColumn:)`.
@MainActor
final class GroupNotificationOpener: ObservableObject {
    static let shared = GroupNotificationOpener(isEnabled: GroupsFeature.isEnabled)

    /// The Daily Report sheet the journal window hosts.
    @Published var isPresentingDailyReport = false
    /// "이 글은 더 이상 볼 수 없어요" and friends, shown as an alert.
    @Published var unavailableMessage: String?

    let isEnabled: Bool
    private(set) var gate = GroupNotificationRouteGate()
    private(set) var registrar: GroupNotificationRegistrar?
    /// The last route released by the gate, while it opens (tests await it).
    private(set) var openTask: Task<Void, Never>?
    private weak var model: AppModel?
    private var showColumn: ((NavigationSplitViewColumn) -> Void)?
    private var lockSubscription: AnyCancellable?
    private let makeRegistrar: (GroupsController) -> GroupNotificationRegistrar?

    init(
        isEnabled: Bool,
        makeRegistrar: ((GroupsController) -> GroupNotificationRegistrar?)? = nil
    ) {
        self.isEnabled = isEnabled
        self.makeRegistrar = makeRegistrar ?? { GroupNotificationRegistrar(groups: $0) }
    }

    /// Whether a journal window is attached to open routes in.
    var isAttached: Bool { model != nil }

    /// Phase 2 hook 1: `GroupsController.onOpenRoute` hands every tapped notification here.
    func receive(_ route: GroupNotificationRoute) {
        guard isEnabled, let route = gate.receive(route) else { return }
        startOpening(route)
    }

    /// Phase 2 hook 2: the app lock has read its configuration, so `isLocked` is now real.
    /// Follows the lock and the privacy shield from here on.
    func appLockDidBootstrap(_ appLock: AppLockCoordinator) {
        guard isEnabled else { return }
        updateLock(isLocked: appLock.isLocked, isShielded: appLock.isPrivacyShieldVisible)
        guard lockSubscription == nil else { return }
        lockSubscription = appLock.$isLocked.combineLatest(appLock.$isPrivacyShieldVisible)
            .sink { [weak self] isLocked, isShielded in
                MainActor.assumeIsolated {
                    self?.updateLock(isLocked: isLocked, isShielded: isShielded)
                }
            }
    }

    /// The lock state, from `appLockDidBootstrap` or a test.
    func updateLock(isLocked: Bool, isShielded: Bool) {
        var conditions = gate.conditions
        conditions.isLockSettled = true
        conditions.isLocked = isLocked
        conditions.isShielded = isShielded
        apply(conditions)
    }

    /// The journal window showing `model`; a new model (another account scope) replaces the old
    /// one and gets its own registrar.
    func attach(model: AppModel, showColumn: @escaping (NavigationSplitViewColumn) -> Void) {
        guard isEnabled else { return }
        self.model = model
        self.showColumn = showColumn
        if let groups = model.groups {
            if registrar?.groups !== groups {
                registrar?.stop()
                registrar = makeRegistrar(groups)
                registrar?.start()
            }
        } else {
            registrar?.stop()
            registrar = nil
        }
        var conditions = gate.conditions
        conditions.hasDestination = true
        apply(conditions)
    }

    func detach(model: AppModel) {
        guard self.model === model else { return }
        self.model = nil
        showColumn = nil
        isPresentingDailyReport = false
        var conditions = gate.conditions
        conditions.hasDestination = false
        apply(conditions)
    }

    /// Opens a route now (taps released by the gate, and Daily Report rows).
    func open(_ route: GroupNotificationRoute) async {
        guard isEnabled, let model, let groups = model.groups else { return }
        var memberGroupIDs: Set<UUID>?
        if let groupID = route.groupID {
            if !groups.hasLoaded {
                await groups.start()
            } else if groups.group(groupID) == nil {
                // Joined on another device since the list was loaded?
                await groups.refresh()
            }
            if groups.hasLoaded, groups.accountState.hasGroupAccess {
                memberGroupIDs = Set(groups.groups.map(\.id))
            }
        }
        // The window may have moved on while the list loaded.
        guard self.model === model else { return }
        let destination = GroupNotificationDestination.resolve(
            route, memberGroupIDs: memberGroupIDs)
        switch destination {
        case .dailyReport:
            isPresentingDailyReport = true
        case .group, .post:
            isPresentingDailyReport = false
            model.openGroupNotificationRoute(route)
            if let column = destination.compactColumn { showColumn?(column) }
        case .unavailable(let message):
            unavailableMessage = message
        }
    }

    private func apply(_ conditions: GroupNotificationRouteGate.Conditions) {
        guard let route = gate.update(conditions) else { return }
        startOpening(route)
    }

    private func startOpening(_ route: GroupNotificationRoute) {
        openTask = Task { await open(route) }
    }
}

extension GroupNotificationRoute {
    var groupID: UUID? {
        switch self {
        case .post(let groupID, _), .group(let groupID): groupID
        case .dailyReport: nil
        }
    }
}

// MARK: - Journal window

extension View {
    /// Phase 2 hook 3, on `ContentView`: attaches the journal window to
    /// `GroupNotificationOpener.shared` (which starts the session's notification registrar),
    /// and hosts the Daily Report sheet and the "no longer available" alert. Inert while
    /// `GroupsFeature` is off.
    @ViewBuilder
    func groupNotificationHandling(
        preferredCompactColumn: Binding<NavigationSplitViewColumn>,
        isEnabled: Bool = GroupsFeature.isEnabled
    ) -> some View {
        if isEnabled {
            modifier(
                GroupNotificationHandlingModifier(preferredCompactColumn: preferredCompactColumn))
        } else {
            self
        }
    }
}

private struct GroupNotificationHandlingModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var opener = GroupNotificationOpener.shared
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    func body(content: Content) -> some View {
        content
            .task(id: ObjectIdentifier(model)) {
                let column = $preferredCompactColumn
                opener.attach(model: model) { column.wrappedValue = $0 }
            }
            .onDisappear { opener.detach(model: model) }
            .sheet(isPresented: $opener.isPresentingDailyReport) {
                if let groups = model.groups {
                    DailyReportSheet(groups: groups) { groupID, postID in
                        Task { await opener.open(.post(groupID: groupID, postID: postID)) }
                    }
                    .environmentObject(model)
                }
            }
            .alert(
                opener.unavailableMessage ?? "",
                isPresented: Binding(
                    get: { opener.unavailableMessage != nil },
                    set: { if !$0 { opener.unavailableMessage = nil } })
            ) {
                Button("확인", role: .cancel) {}
            }
    }
}
