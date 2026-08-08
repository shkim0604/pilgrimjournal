import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum AppLockTimeout: Int, Codable, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var id: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue) }

    public var localizedName: String {
        switch self {
        case .immediately: "즉시"
        case .oneMinute: "1분"
        case .fiveMinutes: "5분"
        case .fifteenMinutes: "15분"
        }
    }

    public func shouldLock(
        backgroundedAt: Date,
        activeAt: Date
    ) -> Bool {
        activeAt.timeIntervalSince(backgroundedAt) >= duration
    }
}

public struct AppLockConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var timeout: AppLockTimeout
    public var allowsBiometrics: Bool

    public init(
        isEnabled: Bool = false,
        timeout: AppLockTimeout = .immediately,
        allowsBiometrics: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.timeout = timeout
        self.allowsBiometrics = allowsBiometrics
    }
}

public enum AppLockVerification: Equatable, Sendable {
    case success
    case failed
    case retryAfter(Date)
}

public enum AppLockError: LocalizedError, Equatable, Sendable {
    case passwordTooShort
    case passwordMismatch
    case currentPasswordInvalid
    case keychain(OSStatus)
    case malformedState
    case authenticationUnavailable
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort: "비밀번호는 6자 이상이어야 합니다."
        case .passwordMismatch: "확인 비밀번호가 일치하지 않습니다."
        case .currentPasswordInvalid: "현재 비밀번호가 올바르지 않습니다."
        case let .keychain(status): "기기 보안 저장소 오류입니다(\(status))."
        case .malformedState: "저장된 앱 잠금 정보를 읽을 수 없습니다."
        case .authenticationUnavailable: "이 기기에서 소유자 인증을 사용할 수 없습니다."
        case .authenticationFailed: "기기 소유자 인증에 실패했습니다."
        }
    }
}

public protocol SecureValueStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct KeychainSecureValueStore: SecureValueStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.pilgrimjournal.app-lock",
        account: String = "device-lock"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppLockError.keychain(status) }
        guard let data = result as? Data else { throw AppLockError.malformedState }
        return data
    }

    public func save(_ data: Data) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AppLockError.keychain(updateStatus)
        }
        var insert = identity
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw AppLockError.keychain(addStatus) }
    }

    public func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppLockError.keychain(status)
        }
    }
}

public final class InMemorySecureValueStore: SecureValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    public init() {}

    public func load() -> Data? {
        lock.withLock { value }
    }

    public func save(_ data: Data) {
        lock.withLock { value = data }
    }

    public func delete() {
        lock.withLock { value = nil }
    }
}

public actor AppLockService {
    private struct State: Codable {
        var version = 1
        var configuration: AppLockConfiguration
        var salt: Data
        var verifier: Data
        var iterations: Int
        var failedAttempts: Int
        var retryAfter: Date?
    }

    private let store: any SecureValueStore
    private let iterations: Int

    public init(
        store: any SecureValueStore = KeychainSecureValueStore(),
        iterations: Int = 120_000
    ) {
        self.store = store
        self.iterations = max(1, iterations)
    }

    public func configuration() throws -> AppLockConfiguration {
        try loadState()?.configuration ?? AppLockConfiguration()
    }

    public func configure(
        password: String,
        confirmation: String,
        timeout: AppLockTimeout,
        allowsBiometrics: Bool
    ) throws {
        try validate(password: password, confirmation: confirmation)
        let salt = try randomData(count: 16)
        let state = State(
            configuration: AppLockConfiguration(
                isEnabled: true,
                timeout: timeout,
                allowsBiometrics: allowsBiometrics
            ),
            salt: salt,
            verifier: derive(
                password: password,
                salt: salt,
                iterations: iterations
            ),
            iterations: iterations,
            failedAttempts: 0,
            retryAfter: nil
        )
        try save(state)
    }

    public func changePassword(
        currentPassword: String,
        newPassword: String,
        confirmation: String
    ) throws {
        guard case .success = try verify(password: currentPassword) else {
            throw AppLockError.currentPasswordInvalid
        }
        let existing = try configuration()
        try configure(
            password: newPassword,
            confirmation: confirmation,
            timeout: existing.timeout,
            allowsBiometrics: existing.allowsBiometrics
        )
    }

    public func resetAfterDeviceAuthentication(
        newPassword: String,
        confirmation: String
    ) throws {
        let existing = try configuration()
        try configure(
            password: newPassword,
            confirmation: confirmation,
            timeout: existing.timeout,
            allowsBiometrics: existing.allowsBiometrics
        )
    }

    public func updateConfiguration(
        timeout: AppLockTimeout,
        allowsBiometrics: Bool
    ) throws {
        guard var state = try loadState() else { throw AppLockError.malformedState }
        state.configuration.timeout = timeout
        state.configuration.allowsBiometrics = allowsBiometrics
        try save(state)
    }

    public func disable(currentPassword: String) throws {
        guard case .success = try verify(password: currentPassword) else {
            throw AppLockError.currentPasswordInvalid
        }
        try store.delete()
    }

    public func verify(
        password: String,
        at date: Date = .now
    ) throws -> AppLockVerification {
        guard var state = try loadState(), state.configuration.isEnabled else {
            return .success
        }
        if let retryAfter = state.retryAfter, retryAfter > date {
            return .retryAfter(retryAfter)
        }
        let candidate = derive(
            password: password,
            salt: state.salt,
            iterations: state.iterations
        )
        if constantTimeEqual(candidate, state.verifier) {
            state.failedAttempts = 0
            state.retryAfter = nil
            try save(state)
            return .success
        }

        state.failedAttempts += 1
        if state.failedAttempts >= 3 {
            let exponent = min(state.failedAttempts - 3, 6)
            let delay = min(300, 5 * (1 << exponent))
            state.retryAfter = date.addingTimeInterval(TimeInterval(delay))
        } else {
            state.retryAfter = nil
        }
        try save(state)
        return state.retryAfter.map(AppLockVerification.retryAfter) ?? .failed
    }

    public func clearFailuresAfterDeviceAuthentication() throws {
        guard var state = try loadState() else { return }
        state.failedAttempts = 0
        state.retryAfter = nil
        try save(state)
    }

    private func validate(password: String, confirmation: String) throws {
        guard password.count >= 6 else { throw AppLockError.passwordTooShort }
        guard password == confirmation else { throw AppLockError.passwordMismatch }
    }

    private func loadState() throws -> State? {
        guard let data = try store.load() else { return nil }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 1, state.iterations > 0 else {
                throw AppLockError.malformedState
            }
            return state
        } catch let error as AppLockError {
            throw error
        } catch {
            throw AppLockError.malformedState
        }
    }

    private func save(_ state: State) throws {
        try store.save(JSONEncoder().encode(state))
    }

    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw AppLockError.keychain(status) }
        return data
    }

    private func derive(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int = 32
    ) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        let hashLength = SHA256.Digest.byteCount
        let blockCount = (keyLength + hashLength - 1) / hashLength
        var derived = Data()

        for block in 1 ... blockCount {
            var blockNumber = UInt32(block).bigEndian
            var initial = salt
            withUnsafeBytes(of: &blockNumber) { initial.append(contentsOf: $0) }
            var previous = Data(HMAC<SHA256>.authenticationCode(
                for: initial,
                using: key
            ))
            var accumulator = Array(previous)
            if iterations > 1 {
                for _ in 2 ... iterations {
                    previous = Data(HMAC<SHA256>.authenticationCode(
                        for: previous,
                        using: key
                    ))
                    for index in accumulator.indices {
                        accumulator[index] ^= previous[index]
                    }
                }
            }
            derived.append(contentsOf: accumulator)
        }
        return derived.prefix(keyLength)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

public protocol DeviceOwnerAuthenticating: Sendable {
    func authenticateBiometrics(reason: String) async throws
    func authenticateDeviceOwner(reason: String) async throws
}

public struct LocalDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    public init() {}

    public func authenticateBiometrics(reason: String) async throws {
        try await evaluate(policy: .deviceOwnerAuthenticationWithBiometrics, reason: reason)
    }

    public func authenticateDeviceOwner(reason: String) async throws {
        try await evaluate(policy: .deviceOwnerAuthentication, reason: reason)
    }

    private func evaluate(
        policy: LAPolicy,
        reason: String
    ) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw AppLockError.authenticationUnavailable
        }
        do {
            guard try await context.evaluatePolicy(policy, localizedReason: reason) else {
                throw AppLockError.authenticationFailed
            }
        } catch {
            throw AppLockError.authenticationFailed
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
