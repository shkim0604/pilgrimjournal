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
    /// Overrides the group server's origin in Debug, e.g. `http://localhost:3100` for
    /// `make -C server dev`. With or without a trailing `/api/v1`.
    static let serverURLEnvironmentKey = "PILGRIM_GROUP_SERVER_URL"
    /// `preview` keeps the in-memory `PreviewGroupAPI` in Debug, for UI work without a server.
    static let apiEnvironmentKey = "PILGRIM_GROUP_API"

    /// Builds one journal user's group client from the Keychain account
    /// (`GroupCredentialStore.account(forAppleUser:)`) its session is stored under.
    typealias APIFactory = @MainActor (_ credentialAccount: String) -> any GroupAPI

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

    // MARK: Client

    /// Which group client a session gets.
    enum ClientChoice: Equatable {
        /// `PreviewGroupAPI`: unit tests, SwiftUI previews and `PILGRIM_GROUP_API=preview`.
        case preview
        /// `URLSessionGroupAPI` talking to this server.
        case live(GroupServerConfiguration)
    }

    /// The client for a build and launch environment. Tests and previews always get the
    /// preview client, so they never reach a server or the Keychain session. Otherwise the
    /// live client goes to `https://pilgrim.delight-house.org`; Debug can point it elsewhere
    /// with `PILGRIM_GROUP_SERVER_URL` or keep the preview client with
    /// `PILGRIM_GROUP_API=preview`. Release reads neither variable.
    static func clientChoice(
        environment: [String: String], isDebugBuild: Bool,
        isHostedByTests: Bool = isHostedByTests, client: ClientHeader = defaultClientHeader
    ) -> ClientChoice {
        if isHostedByTests || isRunningPreviews(environment) { return .preview }
        guard isDebugBuild else { return .live(.production(client: client)) }
        if environment[apiEnvironmentKey]?.lowercased() == "preview" { return .preview }
        return .live(serverConfiguration(environment: environment, client: client))
    }

    /// The live client's server: `PILGRIM_GROUP_SERVER_URL` when it is a usable http(s)
    /// origin, otherwise production. The caller decides whether the variable may be read.
    static func serverConfiguration(environment: [String: String], client: ClientHeader)
        -> GroupServerConfiguration
    {
        if let value = environment[serverURLEnvironmentKey],
            let configuration = GroupServerConfiguration(serverURLString: value, client: client)
        {
            return configuration
        }
        return .production(client: client)
    }

    /// The Xcode preview canvas.
    static func isRunningPreviews(_ environment: [String: String]) -> Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Whether XCTest is loaded in this process (SwiftPM and Xcode test runs).
    static var isHostedByTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// The group-server client each journal session gets, or nil while groups are off.
    static func defaultAPIFactory(
        isEnabled: Bool = isEnabled,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = isDebugBuild,
        isHostedByTests: Bool = isHostedByTests,
        credentialStore: any GroupCredentialStoring = GroupKeychainCredentialStore()
    ) -> APIFactory? {
        guard isEnabled else { return nil }
        switch clientChoice(
            environment: environment, isDebugBuild: isDebugBuild,
            isHostedByTests: isHostedByTests)
        {
        case .preview:
            return { _ in PreviewGroupAPI() }
        case .live(let configuration):
            return { account in
                URLSessionGroupAPI(
                    configuration: configuration, credentialStore: credentialStore,
                    credentialAccount: account)
            }
        }
    }

    /// The live client account deletion uses (`GroupAccountErasure`). It talks to the same
    /// server as the sessions; with the preview client there is no stored session, so the
    /// deletion step finds nothing to do.
    @MainActor
    static func accountDeletionClient(
        account: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        credentialStore: any GroupCredentialStoring = GroupKeychainCredentialStore()
    ) -> URLSessionGroupAPI {
        let client = defaultClientHeader
        let configuration =
            isDebugBuild
            ? serverConfiguration(environment: environment, client: client)
            : .production(client: client)
        return URLSessionGroupAPI(
            configuration: configuration, credentialStore: credentialStore,
            credentialAccount: account)
    }

    /// `X-Pilgrim-Client` for this build. The SwiftPM test host has no app version or a
    /// bundle ID the server knows, so those fall back to the build's own bundle ID.
    static var defaultClientHeader: ClientHeader {
        let bundleID = GroupsController.defaultBundleID
        guard var header = ClientHeader.current() else {
            return ClientHeader(
                platform: .currentPlatform, version: ClientVersion("1.0.0")!, build: "0",
                bundleID: bundleID)
        }
        if !header.isKnownBundle { header.bundleID = bundleID }
        return header
    }

    /// Hosts whose `/i/<code>` links are group invites.
    static let inviteHosts: Set<String> = [APIPaths.productionBaseURL.host ?? ""]
}
