#if canImport(XCTest)
@testable import PilgrimJournal
import XCTest

@MainActor
final class BlockedSignInGuidanceTests: XCTestCase {
    func testOnlyBlockedStatesHaveGuidance() {
        XCTAssertNil(BlockedSignInGuidance(state: .checking))
        XCTAssertNil(BlockedSignInGuidance(state: .signedOut))
        XCTAssertNil(BlockedSignInGuidance(state: .authenticated(offline: false)))
        XCTAssertNil(BlockedSignInGuidance(state: .failed("x")))
        XCTAssertNotNil(BlockedSignInGuidance(state: .blockedDifferentUser))
        XCTAssertNotNil(BlockedSignInGuidance(state: .blockedCloudAccountMismatch))
    }

    // A different Apple user on a device that already has records: the way out
    // is signing in with the original account, so the sign-in button stays.
    func testDifferentUserIsToldToUseTheOriginalAccount() throws {
        let guidance = try XCTUnwrap(BlockedSignInGuidance(state: .blockedDifferentUser))
        XCTAssertFalse(guidance.offersCloudRecheck)
        XCTAssertTrue(guidance.steps.contains { $0.contains("처음") && $0.contains("로그인") })
        XCTAssertTrue(guidance.steps.contains { $0.contains("삭제되지 않") })
    }

    // iCloud bound to another Apple user: either sign in with that user or
    // switch the device's iCloud account, then check again.
    func testCloudMismatchOffersARecheckAfterSwitchingAccounts() throws {
        let guidance = try XCTUnwrap(BlockedSignInGuidance(state: .blockedCloudAccountMismatch))
        XCTAssertTrue(guidance.offersCloudRecheck)
        XCTAssertTrue(guidance.steps.contains { $0.contains("iCloud") && $0.contains("다시 확인") })
        XCTAssertTrue(guidance.steps.contains { $0.contains("삭제되지 않") })
    }
}
#endif
