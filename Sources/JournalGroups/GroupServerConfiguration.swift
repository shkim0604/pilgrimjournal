import Foundation
import PilgrimAPI

/// Where the group server is and how this build identifies itself (design.md 2절).
public struct GroupServerConfiguration: Equatable, Sendable {
    /// The server origin, without `/api/v1` (`https://pilgrim.delight-house.org`,
    /// `http://localhost:3100`). Invite links are built under it too.
    public var serverURL: URL
    /// Sent as `X-Pilgrim-Client` on every request; its bundle ID also goes into sign-in and
    /// device registration bodies.
    public var client: ClientHeader
    /// Per-request timeout for JSON calls.
    public var requestTimeout: TimeInterval
    /// Per-request timeout for `POST /uploads`.
    public var uploadTimeout: TimeInterval

    public init(
        serverURL: URL = APIPaths.productionBaseURL, client: ClientHeader,
        requestTimeout: TimeInterval = 30, uploadTimeout: TimeInterval = 90
    ) {
        self.serverURL = Self.origin(of: serverURL)
        self.client = client
        self.requestTimeout = requestTimeout
        self.uploadTimeout = uploadTimeout
    }

    /// `https://pilgrim.delight-house.org`.
    public static func production(client: ClientHeader) -> GroupServerConfiguration {
        GroupServerConfiguration(serverURL: APIPaths.productionBaseURL, client: client)
    }

    /// `http://localhost:<port>` (`make -C server dev`).
    public static func localDevelopment(port: Int = 3100, client: ClientHeader)
        -> GroupServerConfiguration
    {
        GroupServerConfiguration(
            serverURL: URL(string: "http://localhost:\(port)")!, client: client)
    }

    /// Reads a `PILGRIM_GROUP_SERVER_URL`-style value: an http(s) origin, with or without a
    /// trailing `/api/v1`. nil for an empty or unusable value.
    public init?(serverURLString: String, client: ClientHeader) {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else { return nil }
        self.init(serverURL: url, client: client)
    }

    public var bundleID: String { client.bundleID }

    /// `<serverURL>/api/v1`.
    public var apiBaseURL: URL {
        serverURL.appendingPathComponent("api").appendingPathComponent("v1")
    }

    /// Drops a trailing `/`, `/api/v1` or `/api/v1/` so both spellings of the setting work.
    static func origin(of url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(APIPaths.version1) { path.removeLast(APIPaths.version1.count) }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}

extension ClientHeader {
    /// The header for the running app, from `CFBundleShortVersionString`, `CFBundleVersion`
    /// and the bundle identifier. nil when the bundle lacks any of them (command-line tests).
    public static func current(bundle: Bundle = .main) -> ClientHeader? {
        guard
            let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            let version = ClientVersion(marketing),
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            !build.isEmpty,
            let bundleID = bundle.bundleIdentifier
        else { return nil }
        return ClientHeader(
            platform: .currentPlatform, version: version, build: build, bundleID: bundleID)
    }
}

extension ClientPlatform {
    /// The platform this build runs on.
    public static var currentPlatform: ClientPlatform {
        #if os(macOS)
        .macos
        #else
        .ios
        #endif
    }
}
