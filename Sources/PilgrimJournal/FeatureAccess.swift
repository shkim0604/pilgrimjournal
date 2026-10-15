import Foundation

/// The single gate for paid features. Every premium check goes through here.
@MainActor
protocol FeatureAccess: AnyObject {
    /// Creating, editing, reordering, deleting and restoring journal kinds.
    var canManageKinds: Bool { get }
}

/// Grants every feature. Debug builds can simulate the locked state with
/// `simulateLockedKey` to exercise the premium notice.
@MainActor
final class UnlockedFeatureAccess: FeatureAccess {
    static let simulateLockedKey = "debug-simulate-premium-locked"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var canManageKinds: Bool {
        #if DEBUG
        return !defaults.bool(forKey: Self.simulateLockedKey)
        #else
        return true
        #endif
    }
}
