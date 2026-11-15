import Foundation
import JournalGroups
import PilgrimAPI

// The decisions behind the group subscription (design.md 12, spec "구독 화면"), kept free of
// StoreKit and SwiftUI so they can be tested directly. `GroupSubscriptionController` runs them.

/// Where this user's group subscription stands, as the server's entitlement tells it.
enum GroupSubscriptionState: Equatable {
    /// `SUBSCRIPTION_REQUIRED=false` (the launch setting): groups are free and the subscription
    /// screen never shows.
    case notRequired
    /// Subscribed. `inGracePeriod`: a renewal failed, but Apple keeps the access while the
    /// payment is retried.
    case subscribed(expiresAt: Date?, inGracePeriod: Bool)
    /// Required and not subscribed. The lapse says why an earlier subscription ended (nil:
    /// never subscribed, or nothing the server knows of).
    case required(GroupSubscriptionLapse?)

    init(entitlement: EntitlementResponse) {
        guard entitlement.subscriptionRequired else {
            self = .notRequired
            return
        }
        if entitlement.active {
            self = .subscribed(
                expiresAt: entitlement.expiresAt,
                inGracePeriod: entitlement.status == .gracePeriod)
            return
        }
        switch entitlement.status {
        case .none: self = .required(nil)
        case .billingRetry: self = .required(.billingRetry)
        case .revoked: self = .required(.revoked)
        // `active` or `gracePeriod` but not active: past its expiry.
        case .expired, .active, .gracePeriod: self = .required(.expired)
        }
    }

    /// Whether the user has to buy (or restore) before using groups.
    var needsPurchase: Bool {
        if case .required = self { return true }
        return false
    }

    var isSubscribed: Bool {
        if case .subscribed = self { return true }
        return false
    }
}

/// Why an earlier subscription no longer counts.
enum GroupSubscriptionLapse: Equatable {
    /// A renewal failed and Apple is still retrying, past the grace period.
    case billingRetry
    case expired
    /// Refunded or revoked.
    case revoked
}

/// What to do with a StoreKit transaction for the group server.
enum GroupTransactionSubmission: Equatable {
    /// Send its JWS to `POST /subscriptions/verify`.
    case submit
    /// No group session yet. It stays unfinished, so StoreKit offers it again, and the launch
    /// or sign-in submission sends it.
    case waitForSignIn
    /// Another group account bought it (`appAccountToken`). The server would answer 409, so
    /// it is not sent.
    case ownedByOtherUser
    /// Not the group subscription, or StoreKit could not verify its signature.
    case ignore
}

enum GroupSubscriptionPolicy {
    /// The one product sold (design.md 12).
    static let productID = SubscriptionProduct.groupsMonthly

    /// Whether `requestSubscription()` should show the screen. A fresh `GET /me/entitlement`
    /// wins over the cached profile. Without either (the server is unreachable) the screen
    /// shows, since the server asked for it; it then says it cannot reach the server.
    static func shouldPresentScreen(
        fresh: EntitlementResponse?, cached: EntitlementResponse?
    ) -> Bool {
        guard let entitlement = fresh ?? cached else { return true }
        return GroupSubscriptionState(entitlement: entitlement).needsPurchase
    }

    /// Which transactions go to the server, for the signed-in group user `userID`.
    static func submission(
        for transaction: GroupStoreTransaction, userID: UUID?, productID: String = productID
    ) -> GroupTransactionSubmission {
        guard transaction.productID == productID, transaction.isVerified else { return .ignore }
        guard let userID else { return .waitForSignIn }
        // Offer codes and purchases made outside the app carry no token: the server binds
        // them by the original transaction ID.
        if let token = transaction.appAccountToken, token != userID {
            return .ownedByOtherUser
        }
        return .submit
    }

    /// Whether a transaction is finished after the server's answer to its verification.
    /// Finishing tells StoreKit it was delivered; one left open comes back through
    /// `Transaction.updates` on the next launch, which is the retry when the server was down.
    static func shouldFinish(after error: GroupAPIError?) -> Bool {
        guard let error else { return true }
        switch error.code {
        // A definite answer about this transaction: sending it again changes nothing.
        case .subscriptionInvalid, .subscriptionOwnedByOtherUser: return true
        default: return false
        }
    }

    /// Whether the verification changed what `GroupsController` knows, so `GET /me` has to
    /// be reloaded (its `isEntitled` and account state read the profile's entitlement).
    static func needsAccountReload(
        current: EntitlementResponse?, verified: EntitlementResponse
    ) -> Bool {
        guard let current else { return true }
        return current.subscriptionRequired != verified.subscriptionRequired
            || current.active != verified.active
            || current.status != verified.status
    }

    /// The sheet to reopen once the subscription is in place (or turns out not to be
    /// needed): the join sheet with the same invite code, or group creation. Other sheets
    /// (sign-up, settings) end with the subscription screen.
    static func resumeSheet(openWhenRequested sheet: GroupsSheet?) -> GroupsSheet? {
        switch sheet {
        case .join(let request): .join(GroupJoinRequest(code: request.code))
        case .createGroup: .createGroup
        default: nil
        }
    }
}

/// The group subscription as the App Store sells it in this storefront.
struct GroupSubscriptionOffer: Equatable, Sendable {
    enum Period: Equatable, Sendable {
        case day, week, month, year
    }

    var displayName: String
    /// Already formatted for the storefront, e.g. "₩2,000" or "$1.99".
    var displayPrice: String
    var period: Period
    var periodLength: Int

    /// "₩2,000 / 월": the price with its billing period, as the subscription disclosure
    /// (guideline 3.1.2) requires.
    var priceWithPeriod: String {
        "\(displayPrice) / \(periodDescription)"
    }

    private var periodDescription: String {
        let length = periodLength
        guard length != 1 else {
            switch period {
            case .day: return String(localized: "일")
            case .week: return String(localized: "주")
            case .month: return String(localized: "월")
            case .year: return String(localized: "년")
            }
        }
        switch period {
        case .day: return String(localized: "\(length)일")
        case .week: return String(localized: "\(length)주")
        case .month: return String(localized: "\(length)개월")
        case .year: return String(localized: "\(length)년")
        }
    }
}

/// The subscription screen's texts.
enum GroupSubscriptionMessages {
    static var storeUnavailable: String {
        String(localized: "지금은 App Store에 연결할 수 없어요. 잠시 뒤 다시 시도해 주세요.")
    }

    static var signInFirst: String {
        String(localized: "그룹에 먼저 로그인해 주세요.")
    }

    static var pending: String {
        String(localized: "구입 승인을 기다리고 있어요. 승인되면 자동으로 확인해요.")
    }

    static var unverifiedPurchase: String {
        String(localized: "App Store에서 구입을 확인하지 못했어요.")
    }

    static var ownedByOtherUser: String {
        String(localized: "이 Apple 계정의 구독은 다른 그룹 계정에 연결되어 있어요.")
    }

    static var awaitingServer: String {
        String(localized: "구입은 끝났어요. 그룹 서버에 연결되면 구독을 확인해요.")
    }

    static var restored: String {
        String(localized: "구독을 복원했어요.")
    }

    static var nothingToRestore: String {
        String(localized: "이 Apple 계정에서 복원할 구독이 없어요.")
    }

    static var notActiveAfterVerification: String {
        String(localized: "구독을 확인했지만 지금은 사용 중이 아니에요.")
    }

    static func purchaseFailed(_ reason: String) -> String {
        String(localized: "구입하지 못했어요: \(reason)")
    }

    static func restoreFailed(_ reason: String) -> String {
        String(localized: "구입을 복원하지 못했어요: \(reason)")
    }

    static func lapse(_ lapse: GroupSubscriptionLapse) -> String {
        switch lapse {
        case .billingRetry:
            String(localized: "결제가 되지 않아 구독이 멈췄어요. App Store에서 결제 정보를 확인해 주세요.")
        case .expired:
            String(localized: "구독이 만료됐어요. 다시 구독하면 그룹을 계속 쓸 수 있어요.")
        case .revoked:
            String(localized: "구독이 환불되어 취소됐어요.")
        }
    }

    /// What a server answer to the verification means for the user.
    static func verificationFailed(_ error: GroupAPIError) -> String {
        if error.isUnreachable { return awaitingServer }
        if error.code == .subscriptionOwnedByOtherUser { return ownedByOtherUser }
        return error.localizedMessage
    }
}
