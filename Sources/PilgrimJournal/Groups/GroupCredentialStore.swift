import CryptoKit
import Foundation
import Security

/// Raw secure items keyed by account under one Keychain service.
///
/// A1 defines `GroupCredentialStoring` in JournalGroups for `GroupSessionStore` in parallel;
/// Phase 2 makes `GroupCredentialStore` conform to it (the shapes are meant to match:
/// save/load/delete of `Data` per account) and passes the same instance to the live client,
/// so the session and the installation ID live in one place.
protocol GroupSecureItemStoring: Sendable {
    func save(_ data: Data, for account: String) throws
    func load(for account: String) throws -> Data?
    func delete(for account: String) throws
}

enum GroupCredentialStoreError: Error, Equatable {
    case keychain(OSStatus)
    case malformed

    var message: String {
        String(localized: "이 기기에 그룹 로그인 정보를 저장하지 못했어요. 다시 시도해 주세요.")
    }
}

/// The group session's Keychain home (design.md 3절): `kSecClassGenericPassword`, service
/// `com.dhouse.PilgrimJournal.group-session`, `AfterFirstUnlockThisDeviceOnly`, never
/// synchronized. The session is stored under the hash of the journal's Apple user
/// (`account(forAppleUser:)`), the installation ID under `installation-id`. Nothing here goes
/// to CloudKit, the key-value store or backups.
struct GroupCredentialStore: GroupSecureItemStoring {
    static let service = "com.dhouse.PilgrimJournal.group-session"
    static let installationIDAccount = "installation-id"

    let service: String

    init(service: String = GroupCredentialStore.service) {
        self.service = service
    }

    /// The session's account name: a one-way hash, so the Keychain never holds the Apple ID.
    static func account(forAppleUser identifier: String) -> String {
        let scoped =
            "PilgrimJournal.GroupSession.v1:"
            + identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(scoped.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(for account: String) throws -> Data? {
        var query = identity(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GroupCredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw GroupCredentialStoreError.malformed }
        return data
    }

    func save(_ data: Data, for account: String) throws {
        let identity = identity(account)
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GroupCredentialStoreError.keychain(updateStatus)
        }
        var insert = identity
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GroupCredentialStoreError.keychain(addStatus)
        }
    }

    func delete(for account: String) throws {
        let status = SecItemDelete(identity(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GroupCredentialStoreError.keychain(status)
        }
    }

    /// Removes every item under the service: sessions of any Apple user and the installation
    /// ID (account deletion, A5).
    func deleteAll() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: false,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GroupCredentialStoreError.keychain(status)
        }
    }

    private func identity(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
    }
}

extension GroupSecureItemStoring {
    /// This installation's ID for `POST /auth/*`, made on first use and kept on this device.
    func installationID() throws -> UUID {
        let account = GroupCredentialStore.installationIDAccount
        if let data = try load(for: account) {
            guard let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text)
            else { throw GroupCredentialStoreError.malformed }
            return id
        }
        let id = UUID()
        try save(Data(id.uuidString.lowercased().utf8), for: account)
        return id
    }
}

/// An in-memory store for tests and previews.
final class InMemoryGroupSecureItemStore: GroupSecureItemStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init() {}

    func save(_ data: Data, for account: String) {
        lock.withLock { items[account] = data }
    }

    func load(for account: String) -> Data? {
        lock.withLock { items[account] }
    }

    func delete(for account: String) {
        lock.withLock { items[account] = nil }
    }

    var accounts: Set<String> {
        lock.withLock { Set(items.keys) }
    }
}
