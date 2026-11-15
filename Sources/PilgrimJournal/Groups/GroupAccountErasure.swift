import Foundation
import JournalData
import JournalGroups
import PilgrimAPI
import Security

/// The group-server calls account deletion needs. `URLSessionGroupAPI` has them all; the
/// client is built for one journal user, so its session is that user's.
protocol GroupAccountDeletionClient: Sendable {
    /// Whether this device holds a group session for the client's journal user.
    func hasGroupSession() async -> Bool
    /// `DELETE /me`; ends the client's session once the server confirms.
    func deleteAccount() async throws -> AccountDeletionResponse
    func signInWithApple(identityToken: String, authorizationCode: String, rawNonce: String)
        async throws -> AuthSessionResponse
    func signInForDevelopment(devUser: String) async throws -> AuthSessionResponse
}

extension URLSessionGroupAPI: GroupAccountDeletionClient {
    func hasGroupSession() async -> Bool {
        await session.isSignedIn
    }
}

/// The group Keychain items, listable, so account deletion can tell whether another journal
/// user on this device still has a group session before it drops the installation ID.
protocol GroupSecureItemListing: GroupSecureItemStoring {
    /// Every account under the group Keychain service.
    func allAccounts() throws -> Set<String>
}

extension GroupCredentialStore: GroupSecureItemListing {
    func allAccounts() throws -> Set<String> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: false,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw GroupCredentialStoreError.keychain(status) }
        guard let items = result as? [[String: Any]] else {
            throw GroupCredentialStoreError.malformed
        }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }
}

extension InMemoryGroupSecureItemStore: GroupSecureItemListing {
    func allAccounts() -> Set<String> { accounts }
}

/// Why the group-server step of account deletion stopped. Its text becomes the reason in
/// `AccountDeletionError.remoteDeletionFailed`.
enum GroupAccountErasureError: LocalizedError, Equatable {
    case server(GroupAPIError)
    case appleAuthorization(GroupAppleAuthorizationError)

    var errorDescription: String? {
        switch self {
        case .server(let error):
            GroupMessages.text(for: error)
        case .appleAuthorization(let error):
            error.message ?? String(localized: "Apple 인증을 마치지 않았어요.")
        }
    }
}

/// The group-server step of account deletion (design.md 13절, tasks 2.5.1–2.5.2).
///
/// `AccountDeletionService` runs it before anything in iCloud or on this device is deleted.
/// It throws on any failure, so the service stops with nothing local touched, and it is safe
/// to run again:
///
/// - Groups off, or no group session on this device and nothing left over from an earlier
///   attempt: a quiet success, with no request.
/// - `DELETE /me` answers `alreadyDeleted` for a user the server no longer has.
/// - A session the server no longer accepts (refresh `REFRESH_TOKEN_INVALID`, any rejected
///   refresh): re-authenticate with Apple as the journal's user, sign in to the group server
///   (which finds the account again, or makes an empty one) and delete with that session.
/// - A rejected refresh removes the session from the Keychain on the spot, so a pending
///   marker is written before the first `DELETE /me` and removed only after the server
///   confirmed. A retry after a cancelled or failed re-authentication still finds the marker
///   and deletes instead of skipping the server.
///
/// After the server confirmed, it clears this user's group Keychain items: the session, the
/// marker, and the installation ID unless another journal user on this device still has a
/// group session (their scopes stay, as in the rest of account deletion).
@MainActor
final class GroupAccountErasure: RemoteAccountDataErasing {
    /// Builds the group client for one journal user's Keychain account
    /// (`GroupCredentialStore.account(forAppleUser:)`).
    typealias ClientFactory = @MainActor (_ account: String) -> any GroupAccountDeletionClient

    static let pendingDeletionPrefix = "account-deletion-pending:"

    private let isEnabled: Bool
    private let keychain: any GroupSecureItemListing
    private let authorizer: any GroupAppleAuthorizing
    private let developmentAppleUser: String?
    private let makeClient: ClientFactory

    /// - Parameters:
    ///   - isEnabled: `GroupsFeature.isEnabled`; off makes the step a no-op.
    ///   - keychain: the group Keychain service, the same one the group client keeps its
    ///     session in.
    ///   - developmentAppleUser: Debug's `PILGRIM_DEV_APPLE_USER`; re-authenticates with
    ///     `POST /auth/dev` instead of Apple.
    init(
        isEnabled: Bool = GroupsFeature.isEnabled,
        keychain: any GroupSecureItemListing = GroupCredentialStore(),
        authorizer: (any GroupAppleAuthorizing)? = nil,
        developmentAppleUser: String? = GroupsController.defaultDevelopmentAppleUser,
        makeClient: @escaping ClientFactory
    ) {
        self.isEnabled = isEnabled
        self.keychain = keychain
        self.authorizer = authorizer ?? GroupAppleAuthorizer()
        self.developmentAppleUser = developmentAppleUser
        self.makeClient = makeClient
    }

    static func pendingDeletionAccount(for account: String) -> String {
        pendingDeletionPrefix + account
    }

    func eraseRemoteData(appleUserIdentifier: String) async throws {
        guard isEnabled else { return }
        let account = GroupCredentialStore.account(forAppleUser: appleUserIdentifier)
        let marker = Self.pendingDeletionAccount(for: account)
        let client = makeClient(account)
        let hasSession = await client.hasGroupSession()
        let isPending = ((try? keychain.load(for: marker)) ?? nil) != nil
        guard hasSession || isPending else {
            // Never signed in here (or the session already ended): nothing on the server to
            // reach from this device. Only leftovers in the Keychain go.
            clearKeychain(account: account, marker: marker)
            return
        }
        if !isPending {
            // Best effort: without it a retry after a rejected refresh would skip the server.
            try? keychain.save(Data("1".utf8), for: marker)
        }

        do {
            _ = try await client.deleteAccount()
        } catch {
            let apiError = GroupsController.normalize(error)
            guard apiError.requiresGroupSignIn else {
                throw GroupAccountErasureError.server(apiError)
            }
            try await signInAgain(client, journalUser: appleUserIdentifier)
            do {
                _ = try await client.deleteAccount()
            } catch {
                throw GroupAccountErasureError.server(GroupsController.normalize(error))
            }
        }
        clearKeychain(account: account, marker: marker)
    }

    /// Design.md 13절: a session the server rejected is replaced by a fresh sign-in as the
    /// journal's Apple user; a different Apple user is refused before anything is sent.
    private func signInAgain(_ client: any GroupAccountDeletionClient, journalUser: String)
        async throws
    {
        do {
            if let developmentAppleUser {
                _ = try await client.signInForDevelopment(devUser: developmentAppleUser)
                return
            }
            let nonce = GroupAppleNonce.make()
            let credential = try await authorizer.requestCredential(hashedNonce: nonce.hashed)
            let proof = try GroupAppleAuthorization.verify(
                credential, journalUserIdentifier: journalUser, nonce: nonce)
            _ = try await client.signInWithApple(
                identityToken: proof.identityToken, authorizationCode: proof.authorizationCode,
                rawNonce: proof.rawNonce)
        } catch let error as GroupAppleAuthorizationError {
            throw GroupAccountErasureError.appleAuthorization(error)
        } catch {
            throw GroupAccountErasureError.server(GroupsController.normalize(error))
        }
    }

    /// Best effort: the server account is already gone, so a Keychain failure must not stop
    /// the rest of the deletion.
    private func clearKeychain(account: String, marker: String) {
        try? keychain.delete(for: account)
        try? keychain.delete(for: marker)
        let installationID = GroupCredentialStore.installationIDAccount
        guard let accounts = try? keychain.allAccounts() else { return }
        let others = accounts.subtracting([account, marker, installationID])
        if others.isEmpty {
            try? keychain.delete(for: installationID)
        }
    }
}

// MARK: - Confirmation screen

/// What the account deletion screen says about groups (design.md 13절, task 2.5.3).
struct GroupAccountDeletionNotice: Equatable {
    /// Whether this deletion removes a group-server account (a group profile is loaded).
    var hasGroupAccount: Bool
    /// Groups I run that move to a member vote (or straight to the last member, or away
    /// when nobody is left).
    var adminGroupCount: Int
    /// An App Store subscription the user has to cancel themselves.
    var hasAppStoreSubscription: Bool

    init(me: MeResponse?, groups: [GroupSummary]) {
        hasGroupAccount = me != nil
        adminGroupCount =
            me == nil ? 0 : groups.filter { $0.isAdmin && $0.status != .pendingDeletion }.count
        let subscribed: Set<SubscriptionStatus> = [.active, .gracePeriod, .billingRetry]
        hasAppStoreSubscription = me.map { subscribed.contains($0.entitlement.status) } ?? false
    }

    /// Apple's page for managing App Store subscriptions.
    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
}
