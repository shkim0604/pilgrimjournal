import AuthenticationServices
import Combine
import Foundation
import JournalData

enum AppleCredentialState: Equatable, Sendable {
    case authorized
    case revoked
    case notFound
    case transferred
}

@MainActor
protocol AppleCredentialStateChecking {
    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState
}

@MainActor
struct SystemAppleCredentialStateChecker: AppleCredentialStateChecking {
    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        let state = try await ASAuthorizationAppleIDProvider()
            .credentialState(forUserID: userIdentifier)
        return switch state {
        case .authorized: .authorized
        case .revoked: .revoked
        case .notFound: .notFound
        case .transferred: .transferred
        @unknown default: .notFound
        }
    }
}

@MainActor
final class AppleAuthenticationCoordinator: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case authenticated(offline: Bool)
        case blockedDifferentUser
        case blockedCloudAccountMismatch
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    @Published var errorMessage: String?
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var currentUserIdentifier: String?

    private let service: AppleAuthenticationSessionService
    private let credentialChecker: any AppleCredentialStateChecking
    private let cloudIdentityChecker: (any CloudIdentityBindingChecking)?
    private let bypassForVisualTesting: Bool

    init(
        service: AppleAuthenticationSessionService = AppleAuthenticationSessionService(),
        credentialChecker: (any AppleCredentialStateChecking)? = nil,
        cloudIdentityChecker: (any CloudIdentityBindingChecking)? = nil,
        bypassForVisualTesting: Bool = false
    ) {
        self.service = service
        self.credentialChecker =
            credentialChecker
            ?? SystemAppleCredentialStateChecker()
        self.cloudIdentityChecker = cloudIdentityChecker
        #if DEBUG
        self.bypassForVisualTesting = bypassForVisualTesting
        #else
        self.bypassForVisualTesting = false
        #endif
    }

    var canAccessJournal: Bool {
        if case .authenticated = state { return true }
        return false
    }

    var isUsingOfflineAuthorization: Bool {
        if case .authenticated(offline: true) = state { return true }
        return false
    }

    func bootstrap() async {
        #if DEBUG
        if bypassForVisualTesting {
            state = .authenticated(offline: true)
            errorMessage = nil
            return
        }
        #endif
        state = .checking
        do {
            let session = try await service.session()
            guard let identifier = session.currentUserIdentifier else {
                accountDisplayName = nil
                currentUserIdentifier = nil
                state = .signedOut
                return
            }
            currentUserIdentifier = identifier
            accountDisplayName = Self.accountDisplayName(
                email: session.accountEmail,
                identifier: identifier
            )
            if session.hasOfflineSession {
                // The Keychain session is the last successful authorization.
                // Let returning users in immediately while Apple and CloudKit
                // state are refreshed without covering the journal UI.
                state = .authenticated(offline: true)
                errorMessage = nil
            }
            await verifyCredential(
                identifier: identifier,
                allowsOfflineFallback: session.hasOfflineSession
            )
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func acceptAuthorizedUser(identifier: String, email: String? = nil) async {
        do {
            let session = try await service.acceptAuthorizedUser(
                identifier: identifier,
                email: email
            )
            accountDisplayName = Self.accountDisplayName(
                email: session.accountEmail,
                identifier: identifier
            )
            currentUserIdentifier = identifier
            state = .checking
            await completeAuthentication(identifier: identifier, offline: false)
        } catch AppleAuthenticationSessionError.differentUser {
            currentUserIdentifier = nil
            state = .blockedDifferentUser
            errorMessage = AppleAuthenticationSessionError.differentUser.localizedDescription
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func handleSignInFailure(_ error: Error) {
        if let authorizationError = error as? ASAuthorizationError,
            authorizationError.code == .canceled
        {
            errorMessage = nil
            return
        }
        errorMessage = error.localizedDescription
    }

    func signOut() async {
        do {
            try await service.clearCurrentSession()
            accountDisplayName = nil
            currentUserIdentifier = nil
            state = .signedOut
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleCredentialRevoked() async {
        #if DEBUG
        if bypassForVisualTesting { return }
        #endif
        do {
            try await service.clearCurrentSession()
            accountDisplayName = nil
            currentUserIdentifier = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = .signedOut
    }

    func refreshCredentialState() async {
        #if DEBUG
        if bypassForVisualTesting { return }
        #endif
        guard canAccessJournal else { return }
        do {
            let session = try await service.session()
            guard let identifier = session.currentUserIdentifier else {
                currentUserIdentifier = nil
                state = .signedOut
                return
            }
            await verifyCredential(
                identifier: identifier,
                allowsOfflineFallback: session.hasOfflineSession
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCloudIdentityBinding() async {
        #if DEBUG
        if bypassForVisualTesting { return }
        #endif
        do {
            let session = try await service.session()
            guard let identifier = session.currentUserIdentifier else {
                currentUserIdentifier = nil
                state = .signedOut
                return
            }
            await completeAuthentication(
                identifier: identifier,
                offline: isUsingOfflineAuthorization
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verifyCredential(
        identifier: String,
        allowsOfflineFallback: Bool
    ) async {
        do {
            switch try await credentialChecker.credentialState(for: identifier) {
            case .authorized:
                await completeAuthentication(identifier: identifier, offline: false)
            case .revoked, .notFound, .transferred:
                try await service.clearCurrentSession()
                accountDisplayName = nil
                currentUserIdentifier = nil
                state = .signedOut
            }
        } catch {
            if allowsOfflineFallback {
                state = .authenticated(offline: true)
                errorMessage = nil
            } else {
                state = .signedOut
                errorMessage = "Apple 로그인 상태를 확인할 수 없습니다. 연결 후 다시 시도해 주세요."
            }
        }
    }

    private func completeAuthentication(
        identifier: String,
        offline: Bool
    ) async {
        guard let cloudIdentityChecker else {
            state = .authenticated(offline: offline)
            errorMessage = nil
            return
        }

        switch await cloudIdentityChecker.verifyOrBind(
            userIdentifier: identifier
        ) {
        case .matched, .bound:
            state = .authenticated(offline: offline)
            errorMessage = nil
        case .mismatch:
            state = .blockedCloudAccountMismatch
            errorMessage = "현재 iCloud 저장 공간은 다른 Apple 로그인 사용자에게 연결되어 있습니다."
        case let .unavailable(reason):
            state = .authenticated(offline: offline)
            errorMessage = "iCloud 연결을 확인하지 못해 이 기기에서만 사용합니다: \(reason)"
        }
    }

    private static func accountDisplayName(
        email: String?,
        identifier: String
    ) -> String {
        if let email, !email.isEmpty { return email }
        guard identifier.count > 12 else { return identifier }
        return "Apple 계정 · \(identifier.prefix(6))…\(identifier.suffix(4))"
    }
}
