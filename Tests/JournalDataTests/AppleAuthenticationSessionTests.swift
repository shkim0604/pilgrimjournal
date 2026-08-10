#if canImport(XCTest)
import Foundation
@testable import JournalData
import XCTest

final class AppleAuthenticationSessionTests: XCTestCase {
    func testFirstAuthorizedUserClaimsExistingDataScope() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        let date = Date(timeIntervalSince1970: 1_000)

        let session = try await service.acceptAuthorizedUser(
            identifier: "apple-user-a",
            at: date
        )

        XCTAssertEqual(session.currentUserIdentifier, "apple-user-a")
        XCTAssertEqual(session.boundUserIdentifier, "apple-user-a")
        XCTAssertEqual(session.lastAuthorizedAt, date)
        XCTAssertTrue(session.hasOfflineSession)
    }

    func testLogoutPreservesBindingAndRejectsDifferentUser() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        try await service.acceptAuthorizedUser(identifier: "apple-user-a")

        try await service.clearCurrentSession()
        let signedOut = try await service.session()
        XCTAssertNil(signedOut.currentUserIdentifier)
        XCTAssertEqual(signedOut.boundUserIdentifier, "apple-user-a")

        do {
            try await service.acceptAuthorizedUser(identifier: "apple-user-b")
            XCTFail("다른 사용자는 기존 데이터 범위를 열 수 없어야 합니다.")
        } catch {
            XCTAssertEqual(
                error as? AppleAuthenticationSessionError,
                .differentUser
            )
        }

        let signedInAgain = try await service.acceptAuthorizedUser(
            identifier: "apple-user-a"
        )
        XCTAssertEqual(signedInAgain.currentUserIdentifier, "apple-user-a")
    }
}
#endif
