import Foundation
import PilgrimAPI

/// How a group screen should react to a `GroupAPIError` (tasks 1.6.3).
public enum GroupErrorCategory: Equatable, Sendable {
    /// No connection, a timeout, or the server is down (5xx, tunnel errors). Keep drafts and
    /// show "그룹 서버에 연결할 수 없어요"; the journal is unaffected.
    case unreachable
    /// 426: show the update notice with the App Store link.
    case upgradeRequired
    /// The group session is gone: "그룹에 다시 로그인해 주세요".
    case signInRequired
    /// `SIGNUP_REQUIRED`: show the sign-up screen (name, photo).
    case signupRequired
    /// `SUBSCRIPTION_REQUIRED`: show the subscription screen.
    case subscriptionRequired
    case rateLimited(retryAfter: Int?)
    /// `NOT_FOUND`: the item is gone, expired, or not visible.
    case notFound
    /// The task was cancelled; show nothing.
    case cancelled
    /// Any other answer from the server; the message comes from the code.
    case rejected(APIErrorCode)
    /// A response outside the contract.
    case unexpected
}

extension GroupAPIError {
    public var category: GroupErrorCategory {
        switch self {
        case .offline, .timedOut: return .unreachable
        case .notSignedIn: return .signInRequired
        case .cancelled: return .cancelled
        case .invalidResponse: return .unexpected
        case .server(let status, let error):
            switch error.code {
            case .clientUpgradeRequired: return .upgradeRequired
            case .refreshTokenInvalid, .refreshTokenReused, .unauthenticated, .tokenExpired:
                return .signInRequired
            case .signupRequired: return .signupRequired
            case .subscriptionRequired: return .subscriptionRequired
            case .rateLimited: return .rateLimited(retryAfter: error.retryAfter)
            case .notFound: return .notFound
            case .serviceUnavailable, .internal: return .unreachable
            default:
                if status == 426 { return .upgradeRequired }
                if status >= 500 && error.code == .unknown { return .unreachable }
                return .rejected(error.code)
            }
        }
    }

    /// No connection or the server is down: keep what the user wrote.
    public var isUnreachable: Bool { category == .unreachable }

    /// 426 `CLIENT_UPGRADE_REQUIRED`.
    public var isUpgradeRequired: Bool { category == .upgradeRequired }

    /// The text for this error in the app's language.
    public var localizedMessage: String {
        switch category {
        case .unreachable: GroupStrings.serverUnreachable
        case .upgradeRequired: GroupStrings.upgradeRequired
        case .signInRequired: GroupStrings.signInAgain
        case .signupRequired:
            String(localized: "그룹을 쓰려면 먼저 이름을 정해 주세요", bundle: .module)
        case .subscriptionRequired: String(localized: "그룹을 쓰려면 구독이 필요해요", bundle: .module)
        case .rateLimited:
            String(localized: "요청이 너무 많아요. 잠시 뒤에 다시 시도해 주세요", bundle: .module)
        case .notFound: String(localized: "더 이상 볼 수 없는 항목이에요", bundle: .module)
        case .cancelled: String(localized: "요청이 취소됐어요", bundle: .module)
        case .unexpected: GroupStrings.somethingWentWrong
        case .rejected(let code): Self.message(for: code)
        }
    }

    private static func message(for code: APIErrorCode) -> String {
        switch code {
        case .inviteFull:
            String(localized: "이 초대는 인원이 다 찼어요. 관리자에게 새 초대를 요청해 주세요", bundle: .module)
        case .inviteExpired:
            String(localized: "이 초대는 만료됐어요. 관리자에게 새 초대를 요청해 주세요", bundle: .module)
        case .inviteRevoked:
            String(localized: "이 초대는 취소됐어요. 관리자에게 새 초대를 요청해 주세요", bundle: .module)
        case .inviteLimitReached:
            String(localized: "초대는 그룹마다 20개까지 열어 둘 수 있어요", bundle: .module)
        case .removedFromGroup:
            String(localized: "이 그룹에서 내보내져서 다시 참여할 수 없어요", bundle: .module)
        case .adminVoteInProgress:
            String(localized: "새 관리자를 뽑는 중이라 지금은 할 수 없어요", bundle: .module)
        case .groupPendingDeletion:
            String(localized: "삭제 예정인 그룹이라 지금은 할 수 없어요", bundle: .module)
        case .groupLimitReached:
            String(localized: "더 이상 그룹을 만들거나 참여할 수 없어요", bundle: .module)
        case .voteNotOpen: String(localized: "지금은 진행 중인 투표가 없어요", bundle: .module)
        case .invalidCandidate: String(localized: "후보가 아닌 사람에게는 투표할 수 없어요", bundle: .module)
        case .extendNotAllowed: String(localized: "토론 연장은 독후감만 할 수 있어요", bundle: .module)
        case .stickerLimitReached: String(localized: "이 그룹의 스티커는 30개까지예요", bundle: .module)
        case .mediaInvalid: String(localized: "이 사진은 올릴 수 없어요", bundle: .module)
        case .mediaTooLarge: String(localized: "사진이 너무 커요", bundle: .module)
        case .mediaNotAttachable:
            String(localized: "이 사진은 붙일 수 없어요. 다시 골라 주세요", bundle: .module)
        case .cannotTargetSelf: String(localized: "나 자신에게는 할 수 없어요", bundle: .module)
        case .forbidden: String(localized: "이 작업을 할 권한이 없어요", bundle: .module)
        case .accountSuspended: String(localized: "계정이 정지되어 그룹을 쓸 수 없어요", bundle: .module)
        case .subscriptionInvalid: String(localized: "구독을 확인하지 못했어요", bundle: .module)
        case .subscriptionOwnedByOtherUser:
            String(localized: "이 구독은 다른 그룹 계정에 연결되어 있어요", bundle: .module)
        case .appleTokenInvalid, .appleNonceMismatch, .appleCodeExchangeFailed:
            String(localized: "Apple 인증에 실패했어요. 다시 시도해 주세요", bundle: .module)
        case .validationFailed, .limitExceeded, .invalidRequest:
            String(localized: "입력한 내용을 확인해 주세요", bundle: .module)
        default: GroupStrings.somethingWentWrong
        }
    }
}

extension GroupAPIError: LocalizedError {
    public var errorDescription: String? { localizedMessage }
}

extension ImageCompressionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableImage: String(localized: "사진을 읽을 수 없어요", bundle: .module)
        case .encodingFailed, .cannotFitLimit:
            String(localized: "사진을 줄이지 못했어요. 다른 사진을 골라 주세요", bundle: .module)
        }
    }
}

/// Group texts the app shows outside an error (spec "private-groups").
public enum GroupStrings {
    /// Offline or the server is down.
    public static var serverUnreachable: String {
        String(localized: "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요", bundle: .module)
    }

    /// 426.
    public static var upgradeRequired: String {
        String(localized: "그룹을 쓰려면 앱을 업데이트해 주세요", bundle: .module)
    }

    /// The group session ended (refresh rejected).
    public static var signInAgain: String {
        String(localized: "그룹에 다시 로그인해 주세요", bundle: .module)
    }

    /// The Apple user of the group sign-in is not the journal's (nothing is sent).
    public static var appleAccountMismatch: String {
        String(localized: "기록장에 로그인한 Apple 계정으로 인증해 주세요", bundle: .module)
    }

    public static var somethingWentWrong: String {
        String(localized: "문제가 생겼어요. 잠시 뒤에 다시 시도해 주세요", bundle: .module)
    }
}
