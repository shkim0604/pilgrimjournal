import PilgrimAPI
import Vapor

/// Checks `X-Pilgrim-Client` on every `/api/v1/*` request (design.md 2절, spec "클라이언트 식별과
/// 버전 차단"): missing, malformed or older than `MIN_CLIENT_VERSION` → 426
/// `CLIENT_UPGRADE_REQUIRED`; a bundle ID outside the two app bundles → 400 `INVALID_REQUEST`.
/// The parsed header is available afterwards as `req.pilgrimClient`.
public struct ClientGateMiddleware: AsyncMiddleware {
    let minimumVersion: ClientVersion?
    let allowedBundleIDs: Set<String>

    public init(minimumVersion: ClientVersion?, allowedBundleIDs: Set<String>) {
        self.minimumVersion = minimumVersion
        self.allowedBundleIDs = allowedBundleIDs
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        guard let value = request.headers.first(name: ClientHeader.name),
            let header = ClientHeader(value)
        else {
            throw APIError(
                code: .clientUpgradeRequired, message: "missing or malformed \(ClientHeader.name)")
        }
        guard allowedBundleIDs.contains(header.bundleID) else {
            throw APIError.invalidRequest("unknown bundle id")
        }
        if let minimumVersion, header.version < minimumVersion {
            throw APIError(
                code: .clientUpgradeRequired, message: "client \(header.version) is too old")
        }
        request.storage[ClientHeaderKey.self] = header
        return try await next.respond(to: request)
    }
}

private struct ClientHeaderKey: StorageKey {
    typealias Value = ClientHeader
}

extension Request {
    /// The parsed `X-Pilgrim-Client` header; set on every request under `/api/v1`.
    /// (`req.client` is Vapor's HTTP client, hence the longer name.)
    public var pilgrimClient: ClientHeader? { storage[ClientHeaderKey.self] }
}
