#if canImport(XCTest)
import Foundation
import JournalData
@testable import PilgrimJournal
import XCTest

final class AppLockCoordinatorTests: XCTestCase {
    @MainActor
    func testRelaunchStartsLockedWhenConfigurationPersists() async throws {
        let service = AppLockService(
            store: InMemorySecureValueStore(),
            iterations: 10
        )
        try await service.configure(
            password: "relaunch-password",
            confirmation: "relaunch-password",
            timeout: .fiveMinutes,
            allowsBiometrics: false
        )
        let first = AppLockCoordinator(
            service: service,
            authenticator: SuccessfulAuthenticator()
        )
        await first.bootstrap()
        XCTAssertTrue(first.isLocked)
        let didUnlockFirst = await first.unlock(password: "relaunch-password")
        XCTAssertTrue(didUnlockFirst)

        let relaunched = AppLockCoordinator(
            service: service,
            authenticator: SuccessfulAuthenticator()
        )
        await relaunched.bootstrap()
        XCTAssertTrue(relaunched.isLocked)
    }

    @MainActor
    func testBiometricFailureKeepsLockAndOffersPasswordFallback() async throws {
        let service = AppLockService(
            store: InMemorySecureValueStore(),
            iterations: 10
        )
        try await service.configure(
            password: "fallback-password",
            confirmation: "fallback-password",
            timeout: .immediately,
            allowsBiometrics: true
        )
        let coordinator = AppLockCoordinator(
            service: service,
            authenticator: FailingAuthenticator()
        )
        await coordinator.bootstrap()

        let didUnlockWithBiometrics = await coordinator.unlockWithBiometrics()
        XCTAssertFalse(didUnlockWithBiometrics)
        XCTAssertTrue(coordinator.isLocked)
        XCTAssertTrue(coordinator.errorMessage?.contains("비밀번호") == true)
        let didUnlockWithPassword = await coordinator.unlock(
            password: "fallback-password"
        )
        XCTAssertTrue(didUnlockWithPassword)
    }

    @MainActor
    func testTimeoutHonorsGracePeriodAndLocksAfterBoundary() async throws {
        let service = AppLockService(
            store: InMemorySecureValueStore(),
            iterations: 10
        )
        try await service.configure(
            password: "timeout-password",
            confirmation: "timeout-password",
            timeout: .oneMinute,
            allowsBiometrics: false
        )
        let coordinator = AppLockCoordinator(
            service: service,
            authenticator: SuccessfulAuthenticator()
        )
        await coordinator.bootstrap()
        let didUnlock = await coordinator.unlock(password: "timeout-password")
        XCTAssertTrue(didUnlock)

        let start = Date(timeIntervalSince1970: 1_000)
        coordinator.sceneDidEnterBackground(at: start)
        coordinator.sceneDidBecomeActive(at: start.addingTimeInterval(59))
        XCTAssertFalse(coordinator.isLocked)

        coordinator.sceneDidEnterBackground(at: start.addingTimeInterval(100))
        coordinator.sceneDidBecomeActive(at: start.addingTimeInterval(160))
        XCTAssertTrue(coordinator.isLocked)
    }
}

private struct SuccessfulAuthenticator: DeviceOwnerAuthenticating {
    func authenticateBiometrics(reason: String) async throws {}
    func authenticateDeviceOwner(reason: String) async throws {}
}

private struct FailingAuthenticator: DeviceOwnerAuthenticating {
    func authenticateBiometrics(reason: String) async throws {
        throw AppLockError.authenticationFailed
    }

    func authenticateDeviceOwner(reason: String) async throws {
        throw AppLockError.authenticationFailed
    }
}
#endif
