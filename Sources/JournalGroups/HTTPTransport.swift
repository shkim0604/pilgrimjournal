import Foundation

/// The network seam under `URLSessionGroupAPI`: send one request, get the raw response back.
///
/// Implementations throw transport failures as they come (`URLError`, `CancellationError`);
/// `URLSessionGroupAPI` maps them to `GroupAPIError`. Any HTTP status is a successful send here —
/// the client reads error bodies itself. Tests swap in a scripted fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport over `URLSession`.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = URLSessionHTTPTransport.makeDefaultSession()) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// An ephemeral session: no cookies, no shared URL cache, no credential storage, and no
    /// waiting for connectivity (an offline request fails at once so the UI can say so).
    public static func makeDefaultSession(timeout: TimeInterval = 30) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        return URLSession(configuration: configuration)
    }
}
