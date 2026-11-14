import Foundation

/// Machine-readable error codes (design.md "오류 코드"). The raw value is the JSON string.
///
/// Decoding never fails on a code this build does not know: it becomes `.unknown`, so an older app
/// still shows a generic message for an error a newer server added.
public enum APIErrorCode: String, CaseIterable, Sendable, Codable {
    case invalidRequest = "INVALID_REQUEST"
    case validationFailed = "VALIDATION_FAILED"
    case limitExceeded = "LIMIT_EXCEEDED"
    case unauthenticated = "UNAUTHENTICATED"
    case tokenExpired = "TOKEN_EXPIRED"
    case refreshTokenInvalid = "REFRESH_TOKEN_INVALID"
    case refreshTokenReused = "REFRESH_TOKEN_REUSED"
    case appleTokenInvalid = "APPLE_TOKEN_INVALID"
    case appleNonceMismatch = "APPLE_NONCE_MISMATCH"
    case appleCodeExchangeFailed = "APPLE_CODE_EXCHANGE_FAILED"
    case signupRequired = "SIGNUP_REQUIRED"
    case accountSuspended = "ACCOUNT_SUSPENDED"
    case forbidden = "FORBIDDEN"
    case removedFromGroup = "REMOVED_FROM_GROUP"
    case subscriptionRequired = "SUBSCRIPTION_REQUIRED"
    case subscriptionInvalid = "SUBSCRIPTION_INVALID"
    case subscriptionOwnedByOtherUser = "SUBSCRIPTION_OWNED_BY_OTHER_USER"
    case notFound = "NOT_FOUND"
    case adminVoteInProgress = "ADMIN_VOTE_IN_PROGRESS"
    case groupPendingDeletion = "GROUP_PENDING_DELETION"
    case voteNotOpen = "VOTE_NOT_OPEN"
    case invalidCandidate = "INVALID_CANDIDATE"
    case inviteExpired = "INVITE_EXPIRED"
    case inviteRevoked = "INVITE_REVOKED"
    case inviteFull = "INVITE_FULL"
    case inviteLimitReached = "INVITE_LIMIT_REACHED"
    case groupLimitReached = "GROUP_LIMIT_REACHED"
    case extendNotAllowed = "EXTEND_NOT_ALLOWED"
    case stickerLimitReached = "STICKER_LIMIT_REACHED"
    case mediaInvalid = "MEDIA_INVALID"
    case mediaTooLarge = "MEDIA_TOO_LARGE"
    case mediaNotAttachable = "MEDIA_NOT_ATTACHABLE"
    case cannotTargetSelf = "CANNOT_TARGET_SELF"
    case rateLimited = "RATE_LIMITED"
    case clientUpgradeRequired = "CLIENT_UPGRADE_REQUIRED"
    case `internal` = "INTERNAL"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
    /// A code this build does not know. The server never sends it.
    case unknown = "UNKNOWN"

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = APIErrorCode(rawValue: raw) ?? .unknown
    }

    /// The HTTP status the server answers with for this code.
    public var httpStatus: Int {
        switch self {
        case .invalidRequest: 400
        case .validationFailed, .limitExceeded, .subscriptionInvalid, .invalidCandidate,
            .extendNotAllowed, .mediaInvalid, .cannotTargetSelf:
            422
        case .unauthenticated, .tokenExpired, .refreshTokenInvalid, .refreshTokenReused,
            .appleTokenInvalid, .appleNonceMismatch:
            401
        case .appleCodeExchangeFailed: 502
        case .signupRequired, .accountSuspended, .forbidden, .removedFromGroup: 403
        case .subscriptionRequired: 402
        case .notFound: 404
        case .adminVoteInProgress, .groupPendingDeletion, .voteNotOpen, .inviteFull,
            .inviteLimitReached, .groupLimitReached, .stickerLimitReached, .mediaNotAttachable,
            .subscriptionOwnedByOtherUser:
            409
        case .inviteExpired, .inviteRevoked: 410
        case .mediaTooLarge: 413
        case .rateLimited: 429
        case .clientUpgradeRequired: 426
        case .internal, .unknown: 500
        case .serviceUnavailable: 503
        }
    }
}

/// The `error` object of every 4xx/5xx body.
public struct APIError: Error, Equatable, Sendable, Codable {
    public var code: APIErrorCode
    /// Developer-facing English. Never shown; the app picks its text from `code`.
    public var message: String
    /// The request field that broke a rule (`VALIDATION_FAILED`, `LIMIT_EXCEEDED`).
    public var field: String?
    /// The limit that was exceeded (`LIMIT_EXCEEDED`).
    public var limit: Int?
    /// Seconds to wait (`RATE_LIMITED`, mirrors the `Retry-After` header).
    public var retryAfter: Int?

    public init(
        code: APIErrorCode, message: String, field: String? = nil, limit: Int? = nil,
        retryAfter: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.field = field
        self.limit = limit
        self.retryAfter = retryAfter
    }

    public var httpStatus: Int { code.httpStatus }
}

/// `{ "error": { ... } }`, the body of every error response.
public struct APIErrorBody: Equatable, Sendable, Codable {
    public var error: APIError

    public init(error: APIError) {
        self.error = error
    }
}
