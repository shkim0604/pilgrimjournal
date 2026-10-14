#if canImport(XCTest)
import Foundation
@testable import JournalData
import XCTest

final class AppleAuthenticationSessionTests: XCTestCase {
    func testUnreadableKeychainSessionIsDiscardedForFreshAuthentication() async throws {
        let store = AuthenticationFailingSecureValueStore()
        let service = AppleAuthenticationSessionService(store: store)

        let session = try await service.session()

        XCTAssertEqual(session, AppleAuthenticationSession())
        XCTAssertTrue(store.wasDeleted)
    }

    func testFirstAuthorizedUserClaimsExistingDataScope() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        let date = Date(timeIntervalSince1970: 1_000)

        let session = try await service.acceptAuthorizedUser(
            identifier: "apple-user-a",
            email: "reader@privaterelay.appleid.com",
            at: date
        )

        XCTAssertEqual(session.currentUserIdentifier, "apple-user-a")
        XCTAssertEqual(session.boundUserIdentifier, "apple-user-a")
        XCTAssertEqual(
            session.accountEmail,
            "reader@privaterelay.appleid.com"
        )
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
        XCTAssertNil(signedOut.accountEmail)

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

private final class AuthenticationFailingSecureValueStore: SecureValueStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var shouldFailAuthentication = true
    private var deleted = false

    var wasDeleted: Bool {
        lock.withLock { deleted }
    }

    func load() throws -> Data? {
        try lock.withLock {
            if shouldFailAuthentication {
                throw AppLockError.keychain(-25293)
            }
            return nil
        }
    }

    func save(_ data: Data) {}

    func delete() {
        lock.withLock {
            shouldFailAuthentication = false
            deleted = true
        }
    }
}
#endif
