import Foundation
import PilgrimAPI
import SwiftUI

/// Group invite links (`https://pilgrim.delight-house.org/i/<code>`) opened before groups can
/// act on them — signed out, locked, still loading, or not signed in to the group server yet —
/// wait here until a `GroupsController` takes them. Modelled on `PendingShareInvitations`.
///
/// The same link can arrive twice (the app delegate on a cold launch, the scene delegate, and
/// SwiftUI's `onOpenURL`/`onContinueUserActivity` may all see it), so a code received again
/// within `duplicateWindow` is dropped. While groups are off nothing is accepted, and the link
/// is left to the system.
@MainActor
final class PendingGroupInvite {
    static let shared = PendingGroupInvite(isEnabled: GroupsFeature.isEnabled)

    let isEnabled: Bool
    private let hosts: Set<String>
    private let now: () -> Date
    private let duplicateWindow: TimeInterval
    private var waiting: [InviteCode] = []
    private var lastReceived: [InviteCode: Date] = [:]
    /// Called after a new code is queued.
    var onReceive: (() -> Void)?

    init(
        isEnabled: Bool,
        hosts: Set<String> = GroupsFeature.inviteHosts,
        duplicateWindow: TimeInterval = 5,
        now: @escaping () -> Date = { Date() }
    ) {
        self.isEnabled = isEnabled
        self.hosts = hosts
        self.duplicateWindow = duplicateWindow
        self.now = now
    }

    var hasWaiting: Bool { !waiting.isEmpty }

    /// The invite code in `url` when it is an `https` link to one of `hosts` with the path
    /// `/i/<code>`; nil for any other URL.
    static func inviteCode(
        from url: URL, hosts: Set<String> = GroupsFeature.inviteHosts
    ) -> InviteCode? {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            hosts.contains(host)
        else { return nil }
        return InviteCode(url: url)
    }

    /// Queues the invite in `url`. Returns whether the URL was a group invite this queue took,
    /// so callers can leave other URLs to whoever else handles them.
    @discardableResult
    func add(url: URL) -> Bool {
        guard isEnabled, let code = Self.inviteCode(from: url, hosts: hosts) else { return false }
        add(code)
        return true
    }

    /// Queues the invite in a Universal Link activity (`NSUserActivityTypeBrowsingWeb`).
    @discardableResult
    func add(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
            let url = userActivity.webpageURL
        else { return false }
        return add(url: url)
    }

    /// Queues a typed or scanned code.
    func add(_ code: InviteCode) {
        guard isEnabled else { return }
        let date = now()
        if let previous = lastReceived[code], date.timeIntervalSince(previous) < duplicateWindow {
            return
        }
        lastReceived[code] = date
        if !waiting.contains(code) {
            waiting.append(code)
        }
        onReceive?()
    }

    /// Hands every waiting code to the caller, oldest first, and empties the queue.
    func drain() -> [InviteCode] {
        defer { waiting = [] }
        return waiting
    }
}

extension View {
    /// Sends group invite links that reach SwiftUI (`onOpenURL`, `onContinueUserActivity`) to
    /// `PendingGroupInvite.shared`. Nothing is registered while groups are off.
    func groupInviteLinkHandling(isEnabled: Bool = GroupsFeature.isEnabled) -> some View {
        modifier(GroupInviteLinkHandling(isEnabled: isEnabled))
    }
}

private struct GroupInviteLinkHandling: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onOpenURL { url in
                    PendingGroupInvite.shared.add(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    PendingGroupInvite.shared.add(userActivity: activity)
                }
                #if os(macOS)
            // Let the open window take the link instead of SwiftUI opening another one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                #endif
        } else {
            content
        }
    }
}
