import Foundation
import JournalGroups
import PilgrimAPI

/// The private-groups switch (openspec `add-private-groups`, "그룹 기능 플래그와 진입점").
///
/// On in Debug builds, off in Release, so Release ships with no group section, no group
/// notification handling and no invite Universal Links until the feature is finished. A Debug
/// binary launched directly can turn it off with `PILGRIM_GROUPS=0` (the same way the other
/// `PILGRIM_*` debug switches work); Release ignores the variable.
///
/// Code that needs to test both states takes the flag as a parameter (see
/// `JournalSessionController.init`, `PendingGroupInvite.init`, `GroupNotificationRouting.init`)
/// instead of reading `isEnabled`.
enum GroupsFeature {
    static let environmentKey = "PILGRIM_GROUPS"

    static let isEnabled: Bool = resolve(
        environment: ProcessInfo.processInfo.environment, isDebugBuild: isDebugBuild)

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether groups are on for a build and launch environment.
    static func resolve(environment: [String: String], isDebugBuild: Bool) -> Bool {
        guard isDebugBuild else { return false }
        switch environment[environmentKey]?.lowercased() {
        case "0", "false", "no", "off": return false
        default: return true
        }
    }

    /// The group-server client each journal session gets, or nil while groups are off.
    /// Phase 2 swaps `PreviewGroupAPI` for the live client.
    static func defaultAPIFactory(isEnabled: Bool = isEnabled) -> (@MainActor () -> any GroupAPI)? {
        guard isEnabled else { return nil }
        return { PreviewGroupAPI() }
    }

    /// Hosts whose `/i/<code>` links are group invites.
    static let inviteHosts: Set<String> = [APIPaths.productionBaseURL.host ?? ""]
}
