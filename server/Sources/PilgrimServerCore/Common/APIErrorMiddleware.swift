import PilgrimAPI
import Vapor

/// Turns every thrown error into the PilgrimAPI error envelope (design.md 2절):
/// `{ "error": { "code", "message", "field", "limit", "retryAfter" } }` with the code's HTTP status.
///
/// Handlers throw `APIError` (see the `APIError` helpers below). Vapor's `Abort`, decoding errors
/// and validation errors are mapped to the nearest code. Anything else is a 500 `INTERNAL` whose
/// message is hidden outside development.
public struct APIErrorMiddleware: AsyncMiddleware {
    let exposesInternalMessages: Bool

    public init(exposesInternalMessages: Bool) {
        self.exposesInternalMessages = exposesInternalMessages
    }

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        do {
            return try await next.respond(to: request)
        } catch {
            let apiError = Self.apiError(for: error, exposingInternals: exposesInternalMessages)
            if apiError.code.httpStatus >= 500 {
                request.logger.report(error: error)
            }
            return Self.response(for: apiError, headers: (error as? any AbortError)?.headers)
        }
    }

    public static func response(for error: APIError, headers extra: HTTPHeaders? = nil)
        -> Response
    {
        var headers = HTTPHeaders()
        if let extra {
            for (name, value) in extra where name.lowercased() != "content-type" {
                headers.replaceOrAdd(name: name, value: value)
            }
        }
        headers.contentType = .json
        if let retryAfter = error.retryAfter {
            headers.replaceOrAdd(name: .retryAfter, value: String(retryAfter))
        }
        let body: Data
        do {
            body = try PilgrimJSON.encode(APIErrorBody(error: error))
        } catch {
            body = Data(#"{"error":{"code":"INTERNAL","message":"encoding failed"}}"#.utf8)
        }
        return Response(
            status: HTTPResponseStatus(statusCode: error.httpStatus), headers: headers,
            body: .init(data: body))
    }

    static func apiError(for error: any Error, exposingInternals: Bool) -> APIError {
        switch error {
        case let error as APIError:
            return error
        case let error as DecodingError:
            return APIError(code: .invalidRequest, message: "malformed body: \(error.briefly)")
        case let error as ValidationsError:
            return APIError(code: .validationFailed, message: error.description)
        case let error as any AbortError:
            return APIError(
                code: code(forStatus: error.status),
                message: error.status.code >= 500 && !exposingInternals
                    ? "internal error" : error.reason)
        default:
            return APIError(
                code: .internal, message: exposingInternals ? "\(error)" : "internal error")
        }
    }

    static func code(forStatus status: HTTPResponseStatus) -> APIErrorCode {
        switch status.code {
        case 401: .unauthenticated
        case 403: .forbidden
        case 404, 405: .notFound
        case 413: .mediaTooLarge
        case 422: .validationFailed
        case 426: .clientUpgradeRequired
        case 429: .rateLimited
        case 503: .serviceUnavailable
        case 400..<500: .invalidRequest
        default: .internal
        }
    }
}

extension DecodingError {
    /// The failing coding path without the payload (which may hold user text).
    fileprivate var briefly: String {
        let context: Context
        switch self {
        case .typeMismatch(_, let value), .valueNotFound(_, let value),
            .keyNotFound(_, let value), .dataCorrupted(let value):
            context = value
        @unknown default:
            return "decoding failed"
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        if case .keyNotFound(let key, _) = self {
            return "missing \(path.isEmpty ? key.stringValue : path + "." + key.stringValue)"
        }
        return path.isEmpty ? "invalid value" : "invalid value at \(path)"
    }
}

extension APIError {
    /// 404 `NOT_FOUND` — also the answer for "exists but you may not see it" (design.md 2절).
    public static func notFound(_ message: String = "not found") -> APIError {
        APIError(code: .notFound, message: message)
    }

    public static func forbidden(_ message: String = "forbidden") -> APIError {
        APIError(code: .forbidden, message: message)
    }

    public static func invalidRequest(_ message: String) -> APIError {
        APIError(code: .invalidRequest, message: message)
    }

    public static func validationFailed(field: String, _ message: String) -> APIError {
        APIError(code: .validationFailed, message: message, field: field)
    }

    public static func limitExceeded(field: String, limit: Int, _ message: String? = nil)
        -> APIError
    {
        APIError(
            code: .limitExceeded, message: message ?? "\(field) exceeds \(limit)", field: field,
            limit: limit)
    }

    public static func unauthenticated(_ message: String = "authentication required") -> APIError {
        APIError(code: .unauthenticated, message: message)
    }

    public static func rateLimited(retryAfter seconds: Int) -> APIError {
        APIError(
            code: .rateLimited, message: "too many requests", retryAfter: max(1, seconds))
    }
}
