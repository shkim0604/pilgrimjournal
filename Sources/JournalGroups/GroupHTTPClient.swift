import Foundation
import PilgrimAPI

/// One `/api/v1` call before the access token is attached.
struct GroupEndpoint: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    enum Body: Sendable {
        case none
        case json(Data)
        case multipart(MultipartFormData)
    }

    var method: Method
    /// Path segments under `/api/v1`, unescaped (`["groups", "<id>", "posts"]`).
    var path: [String]
    var query: [URLQueryItem] = []
    var body: Body = .none
    /// false only for `auth/apple`, `auth/dev` and `auth/refresh`.
    var requiresAuthentication = true

    init(
        _ method: Method, _ path: [String], query: [URLQueryItem] = [], body: Body = .none,
        requiresAuthentication: Bool = true
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.requiresAuthentication = requiresAuthentication
    }

    static func json(
        _ method: Method, _ path: [String], _ value: some Encodable,
        requiresAuthentication: Bool = true
    ) throws(GroupAPIError) -> GroupEndpoint {
        let data: Data
        do {
            data = try PilgrimJSON.encode(value)
        } catch {
            // Every request DTO is plain Codable; this would be a programming error.
            throw .invalidResponse(status: 0)
        }
        return GroupEndpoint(
            method, path, body: .json(data), requiresAuthentication: requiresAuthentication)
    }
}

/// Builds `URLRequest`s, sends them through the transport and turns the outcome into a decoded
/// value or a `GroupAPIError`. No token logic: `URLSessionGroupAPI` and `GroupSession` add that.
struct GroupHTTPClient: Sendable {
    let configuration: GroupServerConfiguration
    let transport: any HTTPTransport

    func makeRequest(_ endpoint: GroupEndpoint, accessToken: String?) -> URLRequest {
        var components = URLComponents(
            url: configuration.apiBaseURL, resolvingAgainstBaseURL: false)!
        let encodedSegments = endpoint.path.map(Self.escapePathSegment)
        components.percentEncodedPath += "/" + encodedSegments.joined(separator: "/")
        if !endpoint.query.isEmpty {
            components.percentEncodedQueryItems = endpoint.query.map {
                URLQueryItem(name: $0.name, value: $0.value.map(Self.escapeQueryValue))
            }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = endpoint.method.rawValue
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.client.description, forHTTPHeaderField: ClientHeader.name)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        switch endpoint.body {
        case .none:
            request.timeoutInterval = configuration.requestTimeout
        case .json(let data):
            request.httpBody = data
            request.setValue(
                "application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = configuration.requestTimeout
        case .multipart(let form):
            request.httpBody = form.body
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = configuration.uploadTimeout
        }
        return request
    }

    /// Sends and returns the 2xx body, or throws the mapped error.
    func data(_ endpoint: GroupEndpoint, accessToken: String?) async throws(GroupAPIError)
        -> Data
    {
        if Task.isCancelled { throw .cancelled }
        let request = makeRequest(endpoint, accessToken: accessToken)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw Self.mapTransportError(error)
        }
        if (200..<300).contains(response.statusCode) { return data }
        throw Self.mapErrorResponse(status: response.statusCode, data: data, response: response)
    }

    func send<Response: Decodable>(
        _ endpoint: GroupEndpoint, accessToken: String?, as type: Response.Type
    ) async throws(GroupAPIError) -> Response {
        let data = try await data(endpoint, accessToken: accessToken)
        return try Self.decode(type, from: data)
    }

    static func decode<Response: Decodable>(_ type: Response.Type, from data: Data)
        throws(GroupAPIError) -> Response
    {
        do {
            return try PilgrimJSON.decode(type, from: data)
        } catch {
            throw .invalidResponse(status: 200)
        }
    }

    // MARK: Error mapping

    static func mapTransportError(_ error: any Error) -> GroupAPIError {
        if let error = error as? GroupAPIError { return error }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .offline }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData,
            .cannotDecodeRawData, .zeroByteResource:
            return .invalidResponse(status: 0)
        default:
            // notConnectedToInternet, networkConnectionLost, cannotFindHost,
            // cannotConnectToHost, dnsLookupFailed, TLS failures behind captive portals, …
            return .offline
        }
    }

    static func mapErrorResponse(status: Int, data: Data, response: HTTPURLResponse?)
        -> GroupAPIError
    {
        if var body = try? PilgrimJSON.decode(APIErrorBody.self, from: data) {
            if body.error.retryAfter == nil,
                let header = response?.value(forHTTPHeaderField: "Retry-After"),
                let seconds = Int(header.trimmingCharacters(in: .whitespaces))
            {
                body.error.retryAfter = seconds
            }
            return .server(status: status, error: body.error)
        }
        // No contract body: a proxy or the tunnel answered (Cloudflare 502/530 while the Mac
        // mini is down), or an old server. Keep the meaning of the status where it is clear.
        switch status {
        case 426:
            return .server(
                status: status,
                error: APIError(
                    code: .clientUpgradeRequired, message: "upgrade required (no error body)"))
        case 429:
            let retryAfter = response?.value(forHTTPHeaderField: "Retry-After").flatMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            return .server(
                status: status,
                error: APIError(
                    code: .rateLimited, message: "rate limited (no error body)",
                    retryAfter: retryAfter))
        case 500...599:
            return .server(
                status: status,
                error: APIError(
                    code: .serviceUnavailable, message: "HTTP \(status) without an error body"))
        default:
            return .invalidResponse(status: status)
        }
    }

    // MARK: Escaping

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;?#")
        return set
    }()

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/;")
        return set
    }()

    static func escapePathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? segment
    }

    static func escapeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }
}
