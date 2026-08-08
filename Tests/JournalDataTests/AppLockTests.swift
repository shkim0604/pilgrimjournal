#if canImport(XCTest)
import Foundation
import JournalData
import Security
import XCTest

final class AppLockTests: XCTestCase {
    func testPasswordIsVerifiedWithoutPersistingPlaintext() async throws {
        let store = InMemorySecureValueStore()
        let service = AppLockService(store: store, iterations: 1_000)
        try await service.configure(
            password: "private-journal",
            confirmation: "private-journal",
            timeout: .oneMinute,
            allowsBiometrics: true
        )

        let verification = try await service.verify(
            password: "private-journal"
        )
        XCTAssertEqual(verification, .success)
        XCTAssertFalse(
            (store.load() ?? Data()).contains(Data("private-journal".utf8))
        )
    }

    func testRetryDelaySurvivesServiceRecreation() async throws {
        let store = InMemorySecureValueStore()
        let service = AppLockService(store: store, iterations: 500)
        try await service.configure(
            password: "correct-password",
            confirmation: "correct-password",
            timeout: .immediately,
            allowsBiometrics: false
        )
        let start = Date(timeIntervalSince1970: 100)
        _ = try await service.verify(password: "wrong-password", at: start)
        _ = try await service.verify(password: "wrong-password", at: start)
        let third = try await service.verify(password: "wrong-password", at: start)

        guard case let .retryAfter(expected) = third else {
            return XCTFail("세 번째 실패 후 재시도 제한이 필요합니다.")
        }
        let reopened = AppLockService(store: store, iterations: 1)
        let persistedRetry = try await reopened.verify(
            password: "correct-password",
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(persistedRetry, .retryAfter(expected))
    }

    func testMinimumLengthAndConfirmation() async throws {
        let service = AppLockService(
            store: InMemorySecureValueStore(),
            iterations: 10
        )
        do {
            try await service.configure(
                password: "12345",
                confirmation: "12345",
                timeout: .immediately,
                allowsBiometrics: false
            )
            XCTFail("짧은 비밀번호를 거부해야 합니다.")
        } catch {
            XCTAssertEqual(error as? AppLockError, .passwordTooShort)
        }
    }

    func testKeychainStoreIsThisDeviceOnlyAndNotSynchronizable() throws {
        let service = "com.pilgrimjournal.tests.\(UUID().uuidString)"
        let account = "device-lock"
        let store = KeychainSecureValueStore(service: service, account: account)
        defer { try? store.delete() }

        try store.save(Data("anonymous-verifier".utf8))

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(query as CFDictionary, &result),
            errSecSuccess
        )
        XCTAssertEqual(result as? Data, Data("anonymous-verifier".utf8))
        let synchronizableQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        XCTAssertEqual(
            SecItemCopyMatching(synchronizableQuery as CFDictionary, nil),
            errSecItemNotFound
        )
    }

    func testConfigurationsRemainIsolatedPerDeviceStore() async throws {
        let macStore = InMemorySecureValueStore()
        let phoneStore = InMemorySecureValueStore()
        let macService = AppLockService(store: macStore, iterations: 10)
        let phoneService = AppLockService(store: phoneStore, iterations: 10)
        try await macService.configure(
            password: "mac-password",
            confirmation: "mac-password",
            timeout: .oneMinute,
            allowsBiometrics: false
        )

        let macConfiguration = try await macService.configuration()
        let phoneConfiguration = try await phoneService.configuration()
        XCTAssertTrue(macConfiguration.isEnabled)
        XCTAssertFalse(phoneConfiguration.isEnabled)
        XCTAssertNil(phoneStore.load())
    }
}
#endif
