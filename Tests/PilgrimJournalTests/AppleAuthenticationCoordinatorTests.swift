#if canImport(XCTest)
import Foundation
import JournalData
@testable import PilgrimJournal
import XCTest

final class AppleAuthenticationCoordinatorTests: XCTestCase {
    @MainActor
    func testAuthorizedCredentialRestoresSession() async throws {
        let store = InMemorySecureValueStore()
        let service = AppleAuthenticationSessionService(store: store)
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )

        await coordinator.bootstrap()

        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertTrue(coordinator.canAccessJournal)
    }

    @MainActor
    func testCachedSessionAllowsAccessWhileCredentialRefreshIsPending() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let checker = SuspendingCredentialChecker()
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: checker
        )

        let bootstrap = Task { await coordinator.bootstrap() }
        while !checker.didStart {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.state, .authenticated(offline: true))
        XCTAssertTrue(coordinator.canAccessJournal)

        checker.finish(with: .authorized)
        await bootstrap.value
        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
    }

    @MainActor
    func testCredentialCheckFailureUsesLastAuthorizedOfflineSession() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .failure(StubError.offline))
        )

        await coordinator.bootstrap()

        XCTAssertEqual(coordinator.state, .authenticated(offline: true))
        XCTAssertTrue(coordinator.isUsingOfflineAuthorization)
    }

    @MainActor
    func testRevokedCredentialClearsSessionAndRequiresSignIn() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.revoked))
        )

        await coordinator.bootstrap()

        XCTAssertEqual(coordinator.state, .signedOut)
        let session = try await service.session()
        XCTAssertNil(session.currentUserIdentifier)
    }

    @MainActor
    func testDifferentUserIsBlockedAndLogoutDoesNotRemoveBinding() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user-a")
        await coordinator.signOut()
        await coordinator.acceptAuthorizedUser(identifier: "apple-user-b")

        XCTAssertEqual(coordinator.state, .blockedDifferentUser)
        let session = try await service.session()
        XCTAssertEqual(session.boundUserIdentifier, "apple-user-a")
    }

    @MainActor
    func testCloudAccountBoundToDifferentAppleUserBlocksJournal() async {
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(
                store: InMemorySecureValueStore()
            ),
            credentialChecker: StubCredentialChecker(
                result: .success(.authorized)
            ),
            cloudIdentityChecker: StubCloudIdentityChecker(result: .mismatch)
        )

        await coordinator.acceptAuthorizedUser(identifier: "apple-user")

        XCTAssertEqual(coordinator.state, .blockedCloudAccountMismatch)
        XCTAssertFalse(coordinator.canAccessJournal)
    }

    @MainActor
    func testUnavailableICloudKeepsLocalOnlyJournalAccess() async {
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(
                store: InMemorySecureValueStore()
            ),
            credentialChecker: StubCredentialChecker(
                result: .success(.authorized)
            ),
            cloudIdentityChecker: StubCloudIdentityChecker(
                result: .unavailable(reason: "offline")
            )
        )

        await coordinator.acceptAuthorizedUser(identifier: "apple-user")

        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertTrue(coordinator.canAccessJournal)
        XCTAssertNotNil(coordinator.errorMessage)
    }
}

@MainActor
private final class StubCredentialChecker: AppleCredentialStateChecking {
    let result: Result<AppleCredentialState, Error>

    init(result: Result<AppleCredentialState, Error>) {
        self.result = result
    }

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        try result.get()
    }
}

@MainActor
private final class SuspendingCredentialChecker: AppleCredentialStateChecking {
    private var continuation: CheckedContinuation<AppleCredentialState, Never>?
    private(set) var didStart = false

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        didStart = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(with state: AppleCredentialState) {
        continuation?.resume(returning: state)
        continuation = nil
    }
}

private enum StubError: Error {
    case offline
}

private struct StubCloudIdentityChecker: CloudIdentityBindingChecking {
    let result: CloudIdentityBindingResult

    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        result
    }
}
#endif
