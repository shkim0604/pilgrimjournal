import Combine
import Foundation
import JournalData

@MainActor
final class AppLockCoordinator: ObservableObject {
    @Published private(set) var configuration = AppLockConfiguration()
    @Published private(set) var isLocked = false
    @Published private(set) var isPrivacyShieldVisible = false
    @Published private(set) var retryAfter: Date?
    @Published var errorMessage: String?

    private let service: AppLockService
    private let authenticator: any DeviceOwnerAuthenticating
    private var backgroundedAt: Date?
    private var hasBootstrapped = false
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
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await reloadConfiguration()
        isLocked = configuration.isEnabled
        isPrivacyShieldVisible = false
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
                errorMessage = "비밀번호가 올바르지 않습니다."
            case let .retryAfter(until):
                retryAfter = until
                errorMessage = "잠시 후 다시 시도하세요."
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
                reason: "Pilgrim Journal의 기록을 여세요."
            )
            try await service.clearFailuresAfterDeviceAuthentication()
            retryTask?.cancel()
            retryAfter = nil
            isLocked = false
            return true
        } catch {
            errorMessage = "생체 인증을 사용할 수 없습니다. 비밀번호를 입력하세요."
            return false
        }
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
                reason: "Pilgrim Journal 앱 잠금 비밀번호를 재설정하세요."
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

    private func reloadConfiguration() async {
        do {
            configuration = try await service.configuration()
        } catch {
            configuration = AppLockConfiguration()
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
            if self?.errorMessage == "잠시 후 다시 시도하세요." {
                self?.errorMessage = nil
            }
        }
    }
}
