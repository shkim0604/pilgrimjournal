import Combine
import Foundation
import JournalData

@MainActor
final class AppLockCoordinator: ObservableObject {
    @Published private(set) var configuration = AppLockConfiguration()
    @Published private(set) var isLocked = false
    @Published private(set) var isPrivacyShieldVisible = false
    @Published private(set) var retryAfter: Date?
    /// False until the stored settings have been read; the journal must not
    /// be shown before then, or it is visible for a moment with the lock on.
    @Published private(set) var isBootstrapped = false
    /// The stored settings could not be read. The lock then stays on (a read
    /// error must never turn it off) and only device-owner authentication opens it.
    @Published private(set) var isConfigurationUnreadable = false
    @Published var errorMessage: String? {
        didSet { isShowingRetryMessage = false }
    }

    /// True only while `errorMessage` is the lockout "try again later" message,
    /// so the retry timer can clear it without comparing localized text.
    private var isShowingRetryMessage = false
    private let service: AppLockService
    private let authenticator: any DeviceOwnerAuthenticating
    private var backgroundedAt: Date?
    private var didStartBootstrap = false
    private var retryTask: Task<Void, Never>?
    private var systemAuthenticationGraceUntil: Date?

    init(
        service: AppLockService = AppLockService(),
        authenticator: any DeviceOwnerAuthenticating = LocalDeviceOwnerAuthenticator()
    ) {
        self.service = service
        self.authenticator = authenticator
    }

    func bootstrap() async {
        guard !didStartBootstrap else { return }
        didStartBootstrap = true
        await reloadConfiguration()
        isLocked = configuration.isEnabled
        isPrivacyShieldVisible = false
        isBootstrapped = true
    }

    func sceneWillResignActive(at date: Date = .now) {
        guard configuration.isEnabled else { return }
        isPrivacyShieldVisible = true
        if configuration.timeout == .immediately,
            !(systemAuthenticationGraceUntil.map { $0 > date } ?? false)
        {
            isLocked = true
        }
        if backgroundedAt == nil { backgroundedAt = date }
    }

    func sceneDidEnterBackground(at date: Date = .now) {
        guard configuration.isEnabled else { return }
        isPrivacyShieldVisible = true
        backgroundedAt = backgroundedAt ?? date
    }

    func sceneDidBecomeActive(at date: Date = .now) {
        guard configuration.isEnabled else {
            isPrivacyShieldVisible = false
            backgroundedAt = nil
            return
        }
        if systemAuthenticationGraceUntil.map({ $0 > date }) == true {
            systemAuthenticationGraceUntil = nil
            backgroundedAt = nil
            isPrivacyShieldVisible = false
            return
        }
        if let backgroundedAt,
            configuration.timeout.shouldLock(
                backgroundedAt: backgroundedAt,
                activeAt: date
            )
        {
            isLocked = true
        }
        self.backgroundedAt = nil
        isPrivacyShieldVisible = false
    }

    func lockNow() {
        guard configuration.isEnabled else { return }
        isLocked = true
        isPrivacyShieldVisible = false
    }

    func unlock(password: String, at date: Date = .now) async -> Bool {
        errorMessage = nil
        do {
            switch try await service.verify(password: password, at: date) {
            case .success:
                retryTask?.cancel()
                retryAfter = nil
                isLocked = false
                return true
            case .failed:
                errorMessage = String(localized: "비밀번호가 올바르지 않습니다.")
            case let .retryAfter(until):
                retryAfter = until
                errorMessage = String(localized: "잠시 후 다시 시도하세요.")
                isShowingRetryMessage = true
                scheduleRetryClear(at: until)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func unlockWithBiometrics() async -> Bool {
        guard configuration.isEnabled, configuration.allowsBiometrics else { return false }
        errorMessage = nil
        systemAuthenticationGraceUntil = .now.addingTimeInterval(120)
        defer {
            systemAuthenticationGraceUntil = .now.addingTimeInterval(2)
        }
        do {
            try await authenticator.authenticateBiometrics(
                reason: String(localized: "Pilgrim Journal의 기록을 여세요.")
            )
            try await service.clearFailuresAfterDeviceAuthentication()
            retryTask?.cancel()
            retryAfter = nil
            isLocked = false
            return true
        } catch {
            errorMessage = String(localized: "생체 인증을 사용할 수 없습니다. 비밀번호를 입력하세요.")
            return false
        }
    }

    /// Opens a lock whose stored settings could not be read, with the device
    /// passcode or biometrics, then tries to read the settings again.
    func unlockWithDeviceOwner() async -> Bool {
        guard isConfigurationUnreadable else { return false }
        errorMessage = nil
        systemAuthenticationGraceUntil = .now.addingTimeInterval(120)
        defer {
            systemAuthenticationGraceUntil = .now.addingTimeInterval(2)
        }
        do {
            try await authenticator.authenticateDeviceOwner(
                reason: String(localized: "Pilgrim Journal의 기록을 여세요.")
            )
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        isLocked = false
        await reloadConfiguration()
        return true
    }

    func configure(
        password: String,
        confirmation: String,
        timeout: AppLockTimeout,
        allowsBiometrics: Bool
    ) async -> Bool {
        errorMessage = nil
        do {
            try await service.configure(
                password: password,
                confirmation: confirmation,
                timeout: timeout,
                allowsBiometrics: allowsBiometrics
            )
            await reloadConfiguration()
            isLocked = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateConfiguration(
        timeout: AppLockTimeout,
        allowsBiometrics: Bool
    ) async -> Bool {
        errorMessage = nil
        do {
            try await service.updateConfiguration(
                timeout: timeout,
                allowsBiometrics: allowsBiometrics
            )
            await reloadConfiguration()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func changePassword(
        currentPassword: String,
        newPassword: String,
        confirmation: String
    ) async -> Bool {
        errorMessage = nil
        do {
            try await service.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword,
                confirmation: confirmation
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disable(currentPassword: String) async -> Bool {
        errorMessage = nil
        do {
            try await service.disable(currentPassword: currentPassword)
            await reloadConfiguration()
            isLocked = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func resetPassword(
        newPassword: String,
        confirmation: String
    ) async -> Bool {
        errorMessage = nil
        systemAuthenticationGraceUntil = .now.addingTimeInterval(120)
        defer {
            systemAuthenticationGraceUntil = .now.addingTimeInterval(2)
        }
        do {
            try await authenticator.authenticateDeviceOwner(
                reason: String(localized: "Pilgrim Journal 앱 잠금 비밀번호를 재설정하세요.")
            )
            try await service.resetAfterDeviceAuthentication(
                newPassword: newPassword,
                confirmation: confirmation
            )
            retryTask?.cancel()
            retryAfter = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Forgets the in-memory lock state after account deletion removed the
    /// Keychain item, so the next sign-in starts unlocked and re-reads it.
    func resetAfterAccountDeletion() {
        retryTask?.cancel()
        retryTask = nil
        configuration = AppLockConfiguration()
        isLocked = false
        isPrivacyShieldVisible = false
        retryAfter = nil
        errorMessage = nil
        backgroundedAt = nil
        systemAuthenticationGraceUntil = nil
        isConfigurationUnreadable = false
        didStartBootstrap = false
        isBootstrapped = false
    }

    private func reloadConfiguration() async {
        do {
            configuration = try await service.configuration()
            isConfigurationUnreadable = false
        } catch {
            // Fail closed: lock immediately on every resign until the settings read again.
            isConfigurationUnreadable = true
            if !configuration.isEnabled {
                configuration = AppLockConfiguration(
                    isEnabled: true, timeout: .immediately, allowsBiometrics: false)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleRetryClear(at date: Date) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.retryAfter == date else { return }
            self?.retryAfter = nil
            if self?.isShowingRetryMessage == true {
                self?.errorMessage = nil
            }
        }
    }
}
