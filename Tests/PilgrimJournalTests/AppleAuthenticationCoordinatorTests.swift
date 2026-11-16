#if canImport(XCTest)
import AuthenticationServices
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
        XCTAssertEqual(
            coordinator.accountDisplayName,
            "apple-user"
        )
    }

    @MainActor
    func testProvidedAppleEmailIsDisplayedAndRestoredFromKeychain() async throws {
        let service = AppleAuthenticationSessionService(
            store: InMemorySecureValueStore()
        )
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )

        await coordinator.acceptAuthorizedUser(
            identifier: "apple-user",
            email: "reader@privaterelay.appleid.com"
        )
        XCTAssertEqual(
            coordinator.accountDisplayName,
            "reader@privaterelay.appleid.com"
        )

        let restored = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )
        await restored.bootstrap()
        XCTAssertEqual(
            restored.accountDisplayName,
            "reader@privaterelay.appleid.com"
        )
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
    func testCanceledSignInLeavesUserSignedOutWithoutAnError() async {
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(
                store: InMemorySecureValueStore()
            ),
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )
        await coordinator.bootstrap()
        XCTAssertEqual(coordinator.state, .signedOut)

        coordinator.handleSignInFailure(ASAuthorizationError(.canceled))

        // Cancelling is a deliberate user action, not an error to report.
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertFalse(coordinator.canAccessJournal)
    }

    @MainActor
    func testFailedSignInSurfacesErrorAndKeepsJournalCovered() async {
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(
                store: InMemorySecureValueStore()
            ),
            credentialChecker: StubCredentialChecker(result: .success(.authorized))
        )
        await coordinator.bootstrap()

        coordinator.handleSignInFailure(ASAuthorizationError(.failed))

        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertFalse(coordinator.canAccessJournal)
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
    func testMismatchLeavesNothingThatLetsTheNextLaunchIn() async throws {
        let service = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        let verification = RecordingCloudIdentityVerification(canOpen: true)
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            cloudIdentityChecker: StubCloudIdentityChecker(result: .mismatch),
            cloudIdentityVerification: verification
        )

        await coordinator.acceptAuthorizedUser(identifier: "apple-user-b")

        XCTAssertEqual(coordinator.state, .blockedCloudAccountMismatch)
        XCTAssertEqual(verification.forgotten, ["apple-user-b"])
        XCTAssertTrue(verification.verified.isEmpty)
        let session = try await service.session()
        XCTAssertFalse(session.hasOfflineSession)

        for result: Result<AppleCredentialState, Error> in [
            .failure(StubError.offline), .success(.authorized),
        ] {
            let relaunched = AppleAuthenticationCoordinator(
                service: service,
                credentialChecker: StubCredentialChecker(result: result),
                cloudIdentityChecker: StubCloudIdentityChecker(result: .mismatch),
                cloudIdentityVerification: verification
            )
            await relaunched.bootstrap()
            XCTAssertEqual(relaunched.state, .signedOut)
            XCTAssertFalse(relaunched.canAccessJournal)
        }
    }

    @MainActor
    func testCloudRecheckAfterMismatchLetsTheUserBackIn() async throws {
        let service = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        let cloudChecker = SwitchableCloudIdentityChecker(result: .mismatch)
        let verification = RecordingCloudIdentityVerification(canOpen: true)
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            cloudIdentityChecker: cloudChecker,
            cloudIdentityVerification: verification
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user")
        XCTAssertEqual(coordinator.state, .blockedCloudAccountMismatch)

        // The user switched to their own iCloud and pressed ‘iCloud 연결 다시 확인’.
        await cloudChecker.set(.matched)
        await coordinator.refreshCloudIdentityBinding()

        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertEqual(verification.verified, ["apple-user"])
        let session = try await service.session()
        XCTAssertEqual(session.currentUserIdentifier, "apple-user")
    }

    @MainActor
    func testUnverifiedICloudPairWaitsForTheCheckInsteadOfOpeningAtOnce() async throws {
        let service = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let checker = SuspendingCredentialChecker()
        let verification = RecordingCloudIdentityVerification(canOpen: false)
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: checker,
            cloudIdentityChecker: StubCloudIdentityChecker(result: .matched),
            cloudIdentityVerification: verification
        )

        let bootstrap = Task { await coordinator.bootstrap() }
        while !checker.didStart {
            await Task.yield()
        }
        XCTAssertEqual(coordinator.state, .checking)
        XCTAssertFalse(coordinator.canAccessJournal)

        checker.finish(with: .authorized)
        await bootstrap.value
        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertEqual(verification.verified, ["apple-user"])
    }

    @MainActor
    func testVerifiedPairStillOpensWhenAppleCannotBeReached() async throws {
        let service = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        try await service.acceptAuthorizedUser(identifier: "apple-user")
        let coordinator = AppleAuthenticationCoordinator(
            service: service,
            credentialChecker: StubCredentialChecker(result: .failure(StubError.offline)),
            cloudIdentityChecker: StubCloudIdentityChecker(result: .mismatch),
            cloudIdentityVerification: RecordingCloudIdentityVerification(canOpen: true)
        )

        await coordinator.bootstrap()

        XCTAssertEqual(coordinator.state, .authenticated(offline: true))
    }

    @MainActor
    func testSignOutForgetsTheVerifiedPairs() async {
        let verification = RecordingCloudIdentityVerification(canOpen: true)
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(store: InMemorySecureValueStore()),
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            cloudIdentityChecker: StubCloudIdentityChecker(result: .bound),
            cloudIdentityVerification: verification
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user")

        await coordinator.signOut()

        XCTAssertEqual(verification.forgotten, ["apple-user"])
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

    @MainActor
    func testAccountDeletionSignsOutAndReportsCompletion() async throws {
        let deleter = StubAccountDeleter(error: nil)
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(store: InMemorySecureValueStore()),
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            accountDeleter: deleter
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user")
        XCTAssertTrue(coordinator.canAccessJournal)
        let closed = ClosedFlag()

        let deleted = await coordinator.deleteAccount(
            storageLocation: .iCloud(accountHash: "cloud")
        ) {
            await closed.set()
        }

        XCTAssertTrue(deleted)
        XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertTrue(coordinator.didCompleteAccountDeletion)
        XCTAssertEqual(coordinator.accountDeletionPhase, .idle)
        XCTAssertNil(coordinator.currentUserIdentifier)
        XCTAssertNil(coordinator.accountDisplayName)
        let didClose = await closed.value
        XCTAssertTrue(didClose)
        XCTAssertEqual(
            deleter.requests,
            [
                AccountDeletionRequest(
                    appleUserIdentifier: "apple-user",
                    storageLocation: .iCloud(accountHash: "cloud")
                )
            ]
        )

        // Signing in again starts over without the completion notice.
        await coordinator.acceptAuthorizedUser(identifier: "apple-user-b")
        XCTAssertFalse(coordinator.didCompleteAccountDeletion)
    }

    @MainActor
    func testCloudDeletionFailureKeepsJournalAccessibleAndOffersReturn() async {
        let deleter = StubAccountDeleter(error: AccountDeletionError.cloudDeletionFailed("offline"))
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(store: InMemorySecureValueStore()),
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            accountDeleter: deleter
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user")

        let deleted = await coordinator.deleteAccount(
            storageLocation: .iCloud(accountHash: "cloud")
        ) {}

        XCTAssertFalse(deleted)
        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertFalse(coordinator.didCompleteAccountDeletion)
        guard case let .failed(_, canReturnToJournal) = coordinator.accountDeletionPhase else {
            return XCTFail("실패 상태여야 합니다.")
        }
        XCTAssertTrue(canReturnToJournal)

        coordinator.dismissAccountDeletionFailure()
        XCTAssertEqual(coordinator.accountDeletionPhase, .idle)
    }

    @MainActor
    func testLocalDeletionFailureAfterCloudEraseCannotReturnToJournal() async {
        let deleter = StubAccountDeleter(error: AccountDeletionError.localDeletionFailed("busy"))
        let coordinator = AppleAuthenticationCoordinator(
            service: AppleAuthenticationSessionService(store: InMemorySecureValueStore()),
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            accountDeleter: deleter
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user")

        await coordinator.deleteAccount(storageLocation: .iCloud(accountHash: "cloud")) {}

        guard case let .failed(_, canReturnToJournal) = coordinator.accountDeletionPhase else {
            return XCTFail("실패 상태여야 합니다.")
        }
        XCTAssertFalse(canReturnToJournal)
    }

    @MainActor
    func testDeletedAccountLetsDifferentAppleUserSignInWithoutBlock() async throws {
        let sessionService = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        let root = FileManager.default.temporaryDirectory.appending(
            path: "CoordinatorDeletion-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = AppleAuthenticationCoordinator(
            service: sessionService,
            credentialChecker: StubCredentialChecker(result: .success(.authorized)),
            accountDeleter: AccountDeletionService(
                rootURLProvider: { root },
                cloudEraser: nil,
                sessionService: sessionService,
                appLockStore: InMemorySecureValueStore(),
                preferences: NoopPreferences()
            )
        )
        await coordinator.acceptAuthorizedUser(identifier: "apple-user-a")

        await coordinator.deleteAccount(storageLocation: .localOnly) {}
        await coordinator.acceptAuthorizedUser(identifier: "apple-user-b")

        XCTAssertEqual(coordinator.state, .authenticated(offline: false))
        XCTAssertEqual(coordinator.currentUserIdentifier, "apple-user-b")
    }
}

private final class StubAccountDeleter: AccountDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private var recorded: [AccountDeletionRequest] = []

    init(error: Error?) {
        self.error = error
    }

    var requests: [AccountDeletionRequest] {
        lock.withLock { recorded }
    }

    func deleteAccount(
        _ request: AccountDeletionRequest,
        closeLocalStores: @escaping @Sendable () async -> Void
    ) async throws {
        lock.withLock { recorded.append(request) }
        await closeLocalStores()
        if let error { throw error }
    }
}

private actor ClosedFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private struct NoopPreferences: AccountPreferencesClearing {
    func removeSuite(named suiteName: String) {}
    func removeStandardValues(forKeys keys: [String]) {}
    func removeCloudValues(forKeys keys: [String]) {}
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

private actor SwitchableCloudIdentityChecker: CloudIdentityBindingChecking {
    private var result: CloudIdentityBindingResult

    init(result: CloudIdentityBindingResult) {
        self.result = result
    }

    func set(_ result: CloudIdentityBindingResult) {
        self.result = result
    }

    func verifyOrBind(userIdentifier: String) async -> CloudIdentityBindingResult {
        result
    }
}

@MainActor
private final class RecordingCloudIdentityVerification: CloudIdentityVerificationRecording {
    let canOpen: Bool
    private(set) var verified: [String] = []
    private(set) var forgotten: [String] = []

    init(canOpen: Bool) {
        self.canOpen = canOpen
    }

    func canOpenBeforeVerification(appleUserIdentifier: String) async -> Bool {
        canOpen && !forgotten.contains(appleUserIdentifier)
    }

    func markCloudIdentityVerified(appleUserIdentifier: String) async {
        verified.append(appleUserIdentifier)
    }

    func forgetCloudIdentity(appleUserIdentifier: String) {
        forgotten.append(appleUserIdentifier)
    }
}
#endif
