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

    enum AccountDeletionPhase: Equatable {
        case idle
        case deleting
        /// `canReturnToJournal` is false once iCloud is already erased: the
        /// local leftovers must not be reopened, or they would upload again.
        case failed(message: String, canReturnToJournal: Bool)
    }

    nonisolated static let cloudAccountMismatchMessage =
        String(localized: "현재 iCloud 저장 공간은 다른 Apple 로그인 사용자에게 연결되어 있습니다.")

    @Published private(set) var state: State = .checking
    @Published var errorMessage: String?
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var currentUserIdentifier: String?
    @Published private(set) var accountDeletionPhase: AccountDeletionPhase = .idle
    /// Set once an account deletion finishes, so the sign-in screen can say
    /// what was deleted and how to stop using Sign in with Apple.
    @Published private(set) var didCompleteAccountDeletion = false

    private let service: AppleAuthenticationSessionService
    private let credentialChecker: any AppleCredentialStateChecking
    private let cloudIdentityChecker: (any CloudIdentityBindingChecking)?
    private let accountDeleter: (any AccountDeleting)?
    private let bypassForVisualTesting: Bool

    init(
        service: AppleAuthenticationSessionService = AppleAuthenticationSessionService(),
        credentialChecker: (any AppleCredentialStateChecking)? = nil,
        cloudIdentityChecker: (any CloudIdentityBindingChecking)? = nil,
        accountDeleter: (any AccountDeleting)? = nil,
        bypassForVisualTesting: Bool = false
    ) {
        self.service = service
        self.credentialChecker =
            credentialChecker
            ?? SystemAppleCredentialStateChecker()
        self.cloudIdentityChecker = cloudIdentityChecker
        self.accountDeleter = accountDeleter
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

    var isDeletingAccount: Bool {
        accountDeletionPhase == .deleting
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
        didCompleteAccountDeletion = false
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

    /// Deletes the account and, on success, signs out.
    ///
    /// - Parameters:
    ///   - appleUserIdentifier: The user whose data is deleted. Falls back to
    ///     the signed-in user; the developer bypass passes its own.
    ///   - closeJournal: Releases the open stores before anything is deleted.
    /// - Returns: Whether the account was deleted.
    @discardableResult
    func deleteAccount(
        appleUserIdentifier: String? = nil,
        storageLocation: JournalStorageLocation,
        closeJournal: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard !isDeletingAccount else { return false }
        accountDeletionPhase = .deleting
        return await performAccountDeletion(
            appleUserIdentifier: appleUserIdentifier,
            storageLocation: storageLocation,
            closeJournal: closeJournal
        )
    }

    /// Deletes the account of the user whose journal `session` has open.
    @discardableResult
    func deleteAccount(using session: JournalSessionController) async -> Bool {
        guard !isDeletingAccount else { return false }
        // Claim the phase before the first await so a second tap is ignored.
        accountDeletionPhase = .deleting
        let storageLocation = await session.currentStorageLocation()
        return await performAccountDeletion(
            appleUserIdentifier: currentUserIdentifier ?? session.lastAppleUserIdentifier,
            storageLocation: storageLocation,
            closeJournal: { await session.closeForAccountDeletion() }
        )
    }

    private func performAccountDeletion(
        appleUserIdentifier: String?,
        storageLocation: JournalStorageLocation,
        closeJournal: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard let accountDeleter,
            let identifier = appleUserIdentifier ?? currentUserIdentifier
        else {
            accountDeletionPhase = .failed(
                message: AccountDeletionError.invalidUserIdentifier.localizedDescription,
                canReturnToJournal: true
            )
            return false
        }
        do {
            try await accountDeleter.deleteAccount(
                AccountDeletionRequest(
                    appleUserIdentifier: identifier,
                    storageLocation: storageLocation
                ),
                closeLocalStores: closeJournal
            )
        } catch {
            let deletionError = error as? AccountDeletionError
            accountDeletionPhase = .failed(
                message: error.localizedDescription,
                canReturnToJournal: deletionError?.leavesLocalDataIntact ?? true
            )
            return false
        }
        accountDisplayName = nil
        currentUserIdentifier = nil
        errorMessage = nil
        didCompleteAccountDeletion = true
        state = .signedOut
        accountDeletionPhase = .idle
        return true
    }

    /// Leaves the failure screen. The caller reopens the journal when
    /// `canReturnToJournal` allowed it.
    func dismissAccountDeletionFailure() {
        guard case .failed = accountDeletionPhase else { return }
        accountDeletionPhase = .idle
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
        // A deletion in flight has just removed the iCloud binding; checking
        // now would write it straight back.
        guard canAccessJournal, !isDeletingAccount else { return }
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
        guard !isDeletingAccount else { return }
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
                errorMessage = String(localized: "Apple 로그인 상태를 확인할 수 없습니다. 연결 후 다시 시도해 주세요.")
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
            errorMessage = Self.cloudAccountMismatchMessage
        case let .unavailable(reason):
            state = .authenticated(offline: offline)
            errorMessage = String(localized: "iCloud 연결을 확인하지 못해 이 기기에서만 사용합니다: \(reason)")
        }
    }

    private static func accountDisplayName(
        email: String?,
        identifier: String
    ) -> String {
        if let email, !email.isEmpty { return email }
        guard identifier.count > 12 else { return identifier }
        return String(
            localized: "Apple 계정 · \(String(identifier.prefix(6)))…\(String(identifier.suffix(4)))")
    }
}
