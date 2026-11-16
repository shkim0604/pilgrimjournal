#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

final class GroupSubscriptionPolicyTests: XCTestCase {
    private let product = SubscriptionProduct.groupsMonthly
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entitlement(
        required: Bool = true, active: Bool, status: SubscriptionStatus
    ) -> EntitlementResponse {
        EntitlementResponse(
            subscriptionRequired: required, active: active, status: status,
            productId: status == .none ? nil : product, expiresAt: now + 86_400)
    }

    // MARK: State

    func testSubscriptionOffMeansNoScreenWhateverTheStatus() {
        for status in SubscriptionStatus.allCases {
            for active in [true, false] {
                let state = GroupSubscriptionState(
                    entitlement: entitlement(required: false, active: active, status: status))
                XCTAssertEqual(state, .notRequired, "\(status) active=\(active)")
                XCTAssertFalse(state.needsPurchase)
            }
        }
        XCTAssertEqual(GroupSubscriptionState(entitlement: .notRequired), .notRequired)
    }

    func testRequiredStatesMapToTheScreen() {
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: true, status: .active)),
            .subscribed(expiresAt: now + 86_400, inGracePeriod: false))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: true, status: .gracePeriod)),
            .subscribed(expiresAt: now + 86_400, inGracePeriod: true))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: false, status: .none)),
            .required(nil))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: false, status: .billingRetry)),
            .required(.billingRetry))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: false, status: .expired)),
            .required(.expired))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: false, status: .revoked)),
            .required(.revoked))
        XCTAssertEqual(
            GroupSubscriptionState(entitlement: entitlement(active: false, status: .active)),
            .required(.expired), "an active row past its expiry reads as expired")
        XCTAssertTrue(GroupSubscriptionState.required(nil).needsPurchase)
        XCTAssertTrue(
            GroupSubscriptionState.subscribed(expiresAt: nil, inGracePeriod: false).isSubscribed)
    }

    // MARK: When the screen shows

    func testScreenIsSkippedWhenTheServerDoesNotRequireIt() {
        XCTAssertFalse(
            GroupSubscriptionPolicy.shouldPresentScreen(fresh: .notRequired, cached: nil))
        XCTAssertFalse(
            GroupSubscriptionPolicy.shouldPresentScreen(
                fresh: .notRequired, cached: entitlement(active: false, status: .none)),
            "a fresh answer wins over the cached profile")
        XCTAssertFalse(
            GroupSubscriptionPolicy.shouldPresentScreen(
                fresh: nil, cached: .notRequired),
            "offline falls back to the profile")
        XCTAssertFalse(
            GroupSubscriptionPolicy.shouldPresentScreen(
                fresh: entitlement(active: true, status: .active), cached: nil))
    }

    func testScreenShowsWhenRequiredOrUnknown() {
        XCTAssertTrue(
            GroupSubscriptionPolicy.shouldPresentScreen(
                fresh: entitlement(active: false, status: .none), cached: .notRequired))
        XCTAssertTrue(
            GroupSubscriptionPolicy.shouldPresentScreen(
                fresh: nil, cached: entitlement(active: false, status: .expired)))
        XCTAssertTrue(
            GroupSubscriptionPolicy.shouldPresentScreen(fresh: nil, cached: nil),
            "the server asked for a subscription and cannot be reached to say otherwise")
    }

    // MARK: Which transactions go to the server

    func testSubmissionRules() {
        let user = UUID()
        func transaction(
            product: String = SubscriptionProduct.groupsMonthly, verified: Bool = true,
            token: UUID? = nil
        ) -> GroupStoreTransaction {
            GroupStoreTransaction(
                id: 1, productID: product, signedTransaction: "jws", isVerified: verified,
                appAccountToken: token)
        }
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction(token: user), userID: user),
            .submit)
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction(), userID: user), .submit,
            "offer codes carry no appAccountToken")
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction(token: UUID()), userID: user),
            .ownedByOtherUser)
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction(token: user), userID: nil),
            .waitForSignIn)
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(for: transaction(verified: false), userID: user),
            .ignore)
        XCTAssertEqual(
            GroupSubscriptionPolicy.submission(
                for: transaction(product: "com.dhouse.PilgrimJournal.premium.monthly"),
                userID: user),
            .ignore, "PR #27's product is not sold")
    }

    func testOnlyADefiniteAnswerFinishesTheTransaction() {
        XCTAssertTrue(GroupSubscriptionPolicy.shouldFinish(after: nil))
        XCTAssertTrue(GroupSubscriptionPolicy.shouldFinish(after: .server(.subscriptionInvalid)))
        XCTAssertTrue(
            GroupSubscriptionPolicy.shouldFinish(after: .server(.subscriptionOwnedByOtherUser)))
        for error: GroupAPIError in [
            .offline, .timedOut, .cancelled, .notSignedIn, .invalidResponse(status: 502),
            .server(.internal), .server(.serviceUnavailable), .server(.rateLimited),
            .server(.tokenExpired), .server(.clientUpgradeRequired),
        ] {
            XCTAssertFalse(GroupSubscriptionPolicy.shouldFinish(after: error), "\(error)")
        }
    }

    func testAccountReloadOnlyWhenTheGateChanges() {
        let none = entitlement(active: false, status: .none)
        let active = entitlement(active: true, status: .active)
        XCTAssertTrue(GroupSubscriptionPolicy.needsAccountReload(current: nil, verified: active))
        XCTAssertTrue(GroupSubscriptionPolicy.needsAccountReload(current: none, verified: active))
        XCTAssertTrue(
            GroupSubscriptionPolicy.needsAccountReload(current: .notRequired, verified: none))
        var renewed = active
        renewed.expiresAt = now + 40 * 86_400
        XCTAssertFalse(
            GroupSubscriptionPolicy.needsAccountReload(current: active, verified: renewed),
            "a renewal changes nothing GroupsController gates on")
    }

    // MARK: Resuming

    func testResumeReopensJoinWithTheSameCodeOrCreate() throws {
        let code = try XCTUnwrap(InviteCode(normalizing: PreviewGroupAPI.sampleInviteCode))
        let request = GroupJoinRequest(code: code)
        guard
            case .join(let resumed) = GroupSubscriptionPolicy.resumeSheet(
                openWhenRequested: .join(request))
        else { return XCTFail("join resumes") }
        XCTAssertEqual(resumed.code, code)
        XCTAssertNotEqual(resumed.id, request.id, "a new request so the sheet opens again")
        XCTAssertEqual(
            GroupSubscriptionPolicy.resumeSheet(openWhenRequested: .createGroup), .createGroup)
        XCTAssertNil(GroupSubscriptionPolicy.resumeSheet(openWhenRequested: .onboarding))
        XCTAssertNil(GroupSubscriptionPolicy.resumeSheet(openWhenRequested: .subscription))
        XCTAssertNil(GroupSubscriptionPolicy.resumeSheet(openWhenRequested: nil))
    }

    // MARK: Offer

    func testPriceWithPeriod() {
        var offer = GroupSubscriptionOffer(
            displayName: "Pilgrim 그룹 (월간)", displayPrice: "₩2,000", period: .month,
            periodLength: 1)
        XCTAssertEqual(offer.priceWithPeriod, "₩2,000 / 월")
        offer.period = .year
        offer.periodLength = 2
        XCTAssertEqual(offer.priceWithPeriod, "₩2,000 / 2년")
        offer.period = .month
        offer.periodLength = 3
        XCTAssertEqual(offer.priceWithPeriod, "₩2,000 / 3개월")
    }

    func testVerificationMessages() {
        XCTAssertEqual(
            GroupSubscriptionMessages.verificationFailed(.offline),
            GroupSubscriptionMessages.awaitingServer)
        XCTAssertEqual(
            GroupSubscriptionMessages.verificationFailed(.server(.subscriptionOwnedByOtherUser)),
            GroupSubscriptionMessages.ownedByOtherUser)
        XCTAssertEqual(
            GroupSubscriptionMessages.verificationFailed(.server(.subscriptionInvalid)),
            GroupAPIError.server(.subscriptionInvalid).localizedMessage)
    }
}
#endif
