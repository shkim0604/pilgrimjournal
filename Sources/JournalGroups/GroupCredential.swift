import Foundation
import PilgrimAPI

/// A stored group session (design.md 3절 "세션 토큰"). The app keeps it in the Keychain as JSON
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service
/// `GroupCredential.keychainService`, account = the journal's Apple user hash) and never in
/// CloudKit, key-value storage or backups.
public struct GroupCredential: Equatable, Sendable, Codable {
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    public var refreshTokenExpiresAt: Date
    /// The group-server user ID (`MeResponse.id`), not the Apple user.
    public var userId: UUID

    public init(
        accessToken: String, accessTokenExpiresAt: Date, refreshToken: String,
        refreshTokenExpiresAt: Date, userId: UUID
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.userId = userId
    }

    public init(_ session: AuthSessionResponse) {
        self.init(
            accessToken: session.accessToken, accessTokenExpiresAt: session.accessTokenExpiresAt,
            refreshToken: session.refreshToken,
            refreshTokenExpiresAt: session.refreshTokenExpiresAt, userId: session.user.id)
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt, userId
    }

    /// Written by hand so `userId` is a lowercase UUID string like every API ID.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(accessTokenExpiresAt, forKey: .accessTokenExpiresAt)
        try container.encode(refreshToken, forKey: .refreshToken)
        try container.encode(refreshTokenExpiresAt, forKey: .refreshTokenExpiresAt)
        try container.encode(userId.pilgrimString, forKey: .userId)
    }

    /// The Keychain service of the group session and the installation ID.
    public static let keychainService = "com.dhouse.PilgrimJournal.group-session"
    /// The Keychain account under `keychainService` that holds the installation ID.
    public static let installationIDAccount = "installation-id"

    /// The JSON a Keychain adapter stores (`PilgrimJSON`, so dates keep milliseconds).
    public func encoded() throws -> Data {
        try PilgrimJSON.encode(self)
    }

    public static func decoded(from data: Data) throws -> GroupCredential {
        try PilgrimJSON.decode(GroupCredential.self, from: data)
    }
}

/// Where `GroupSession` keeps its tokens. The app supplies the Keychain adapter (A2,
/// `GroupCredentialStore`); `InMemoryGroupCredentialStore` serves tests and previews.
///
/// `account` is the journal session's Apple user hash, so a different journal user on the
/// same device never sees another user's group session.
public protocol GroupCredentialStoring: Sendable {
    func loadCredential(account: String) throws -> GroupCredential?
    func saveCredential(_ credential: GroupCredential, account: String) throws
    func deleteCredential(account: String) throws
    /// The per-install UUID sent as `installationId` (not tied to a journal user).
    func loadInstallationID() throws -> UUID?
    func saveInstallationID(_ id: UUID) throws
}

extension GroupCredentialStoring {
    /// The stored installation ID, creating and saving one on first use. Falls back to a fresh
    /// unsaved ID when the store fails, so sign-in still works (the server then sees a new
    /// device on the next launch).
    public func installationIDCreatingIfNeeded() -> UUID {
        if let id = try? loadInstallationID() { return id }
        let id = UUID()
        try? saveInstallationID(id)
        return id
    }
}

/// A `GroupCredentialStoring` that forgets everything when released.
public final class InMemoryGroupCredentialStore: GroupCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String: GroupCredential]
    private var installationID: UUID?
    /// When set, every save throws it (tests of a failing Keychain).
    private var saveError: (any Error)?

    public init(credentials: [String: GroupCredential] = [:], installationID: UUID? = nil) {
        self.credentials = credentials
        self.installationID = installationID
    }

    public func loadCredential(account: String) throws -> GroupCredential? {
        lock.withLock { credentials[account] }
    }

    public func saveCredential(_ credential: GroupCredential, account: String) throws {
        try lock.withLock {
            if let saveError { throw saveError }
            credentials[account] = credential
        }
    }

    public func deleteCredential(account: String) throws {
        lock.withLock { credentials[account] = nil }
    }

    public func loadInstallationID() throws -> UUID? {
        lock.withLock { installationID }
    }

    public func saveInstallationID(_ id: UUID) throws {
        lock.withLock { installationID = id }
    }

    /// Makes later saves throw `error` (nil restores normal saving).
    public func failSaves(with error: (any Error)?) {
        lock.withLock { saveError = error }
    }

    /// Every stored credential, for assertions.
    public var allCredentials: [String: GroupCredential] {
        lock.withLock { credentials }
    }
}
