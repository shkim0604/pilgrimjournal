import Foundation

/// What one in-app account deletion acts on: the signed-in Apple user and the
/// storage the device uses right now.
public struct AccountDeletionRequest: Equatable, Sendable {
    public var appleUserIdentifier: String
    /// `.iCloud` runs the cloud step first; `.localOnly` skips it, because the
    /// app cannot reach the user's private database from this device.
    public var storageLocation: JournalStorageLocation

    public init(appleUserIdentifier: String, storageLocation: JournalStorageLocation) {
        self.appleUserIdentifier = appleUserIdentifier
        self.storageLocation = storageLocation
    }
}

public enum AccountDeletionError: LocalizedError, Equatable, Sendable {
    case invalidUserIdentifier
    case storageUnavailable(String)
    case cloudAccountOwnedByDifferentUser
    case cloudDeletionFailed(String)
    case localDeletionFailed(String)

    /// Whether this device's records are still in place, so the journal can
    /// be opened again. After `localDeletionFailed` the iCloud copy is already
    /// gone; reopening the store would upload the leftovers again.
    public var leavesLocalDataIntact: Bool {
        switch self {
        case .invalidUserIdentifier, .storageUnavailable, .cloudAccountOwnedByDifferentUser,
            .cloudDeletionFailed:
            true
        case .localDeletionFailed:
            false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidUserIdentifier:
            String(localized: "삭제할 Apple 로그인 사용자를 확인할 수 없습니다.", bundle: .module)
        case let .storageUnavailable(reason):
            String(localized: "기록 저장 위치를 찾지 못해 아무것도 삭제하지 않았습니다. \(reason)", bundle: .module)
        case .cloudAccountOwnedByDifferentUser:
            String(
                localized: "현재 iCloud 저장 공간은 다른 Apple 로그인 사용자에게 연결되어 있어 아무것도 삭제하지 않았습니다.",
                bundle: .module)
        case let .cloudDeletionFailed(reason):
            String(
                localized:
                    "iCloud의 기록을 삭제하지 못했습니다. 이 기기의 데이터는 그대로 두었습니다. 네트워크와 iCloud 연결을 확인한 뒤 다시 시도해 주세요. (\(reason))",
                bundle: .module)
        case let .localDeletionFailed(reason):
            String(
                localized:
                    "iCloud의 기록은 삭제했지만 이 기기의 데이터를 모두 지우지 못했습니다. 다시 시도해 주세요. (\(reason))",
                bundle: .module)
        }
    }
}

/// Removes what one Apple user keeps in the system iCloud private database.
public protocol CloudAccountDataErasing: Sendable {
    func eraseCloudData(appleUserIdentifier: String) async throws
}

/// Deletes the account binding record, then the Core Data mirroring zones.
///
/// The binding goes first on purpose. If the zones then fail to delete, the
/// journal reopens with every record intact and the binding is written again
/// on the next check. The reverse order could leave the zones gone while the
/// app reopens the local store, which re-creates them and re-uploads
/// everything.
public struct CloudKitAccountDataEraser: CloudAccountDataErasing {
    private let bindingStore: any CloudIdentityBindingStore
    private let wipeJournalZones: @Sendable () async throws -> [String]

    public init(containerIdentifier: String) {
        self.init(
            bindingStore: CloudKitIdentityBindingStore(
                containerIdentifier: containerIdentifier
            ),
            wipeJournalZones: {
                try await CloudKitDataWiper.wipePrivateData(
                    containerIdentifier: containerIdentifier
                )
            }
        )
    }

    public init(
        bindingStore: any CloudIdentityBindingStore,
        wipeJournalZones: @escaping @Sendable () async throws -> [String]
    ) {
        self.bindingStore = bindingStore
        self.wipeJournalZones = wipeJournalZones
    }

    public func eraseCloudData(appleUserIdentifier: String) async throws {
        let ownHash = CloudIdentityBindingService.subjectHash(for: appleUserIdentifier)
        if let storedHash = try await bindingStore.loadSubjectHash(),
            storedHash != ownHash
        {
            throw AccountDeletionError.cloudAccountOwnedByDifferentUser
        }
        try await bindingStore.deleteBinding()
        _ = try await wipeJournalZones()
    }
}

/// The preference stores account deletion clears, behind a seam for tests.
public protocol AccountPreferencesClearing: Sendable {
    func removeSuite(named suiteName: String)
    func removeStandardValues(forKeys keys: [String])
    func removeCloudValues(forKeys keys: [String])
}

public struct SystemAccountPreferences: AccountPreferencesClearing {
    public init() {}

    public func removeSuite(named suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    public func removeStandardValues(forKeys keys: [String]) {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    public func removeCloudValues(forKeys keys: [String]) {
        let store = NSUbiquitousKeyValueStore.default
        for key in keys {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }
}

public protocol AccountDeleting: Sendable {
    /// Deletes the account or throws before anything that cannot be undone
    /// when the cloud step fails. `closeLocalStores` runs before any data is
    /// touched, so no open store can re-upload what the cloud step removes.
    func deleteAccount(
        _ request: AccountDeletionRequest,
        closeLocalStores: @escaping @Sendable () async -> Void
    ) async throws
}

/// In-app account deletion: the user's iCloud records, this Apple user's data
/// on this device, and the Keychain items that remember the sign-in.
///
/// Order matters:
/// 1. Close the local stores.
/// 2. Erase iCloud (only for an iCloud scope). A failure stops here, before
///    anything local is gone, so the user can retry once online.
/// 3. Remove this Apple user's files. Other Apple users' scopes on the same
///    device are left alone.
/// 4. Clear this user's preference suites, and the iCloud key-value keys
///    for an iCloud scope.
/// 5. Delete the Keychain items last, so a failed step can still be retried
///    while signed in.
///
/// Apple's token revocation needs a server holding the client secret, which
/// this app does not have; the UI points the user to iOS Settings instead.
public struct AccountDeletionService: AccountDeleting {
    private let rootURLProvider: @Sendable () throws -> URL
    private let cloudEraser: (any CloudAccountDataErasing)?
    private let sessionService: AppleAuthenticationSessionService
    private let appLockStore: any SecureValueStore
    private let preferences: any AccountPreferencesClearing
    private let standardDefaultsKeys: [String]
    private let cloudKeyValueKeys: [String]
    private let temporaryItems: [URL]

    /// - Parameters:
    ///   - rootURLProvider: The account-scope root (`JournalPaths.applicationRoot`).
    ///     Its parent holds the pre-account-scope legacy store.
    ///   - cloudEraser: `nil` where the build has no CloudKit container.
    ///   - standardDefaultsKeys: App-wide keys to reset, such as onboarding.
    ///   - cloudKeyValueKeys: iCloud key-value keys the journal writes.
    ///   - temporaryItems: Plaintext copies under `tmp/` to remove.
    public init(
        rootURLProvider: @escaping @Sendable () throws -> URL,
        cloudEraser: (any CloudAccountDataErasing)?,
        sessionService: AppleAuthenticationSessionService,
        appLockStore: any SecureValueStore = KeychainSecureValueStore(),
        preferences: any AccountPreferencesClearing = SystemAccountPreferences(),
        standardDefaultsKeys: [String] = [],
        cloudKeyValueKeys: [String] = [],
        temporaryItems: [URL] = []
    ) {
        self.rootURLProvider = rootURLProvider
        self.cloudEraser = cloudEraser
        self.sessionService = sessionService
        self.appLockStore = appLockStore
        self.preferences = preferences
        self.standardDefaultsKeys = standardDefaultsKeys
        self.cloudKeyValueKeys = cloudKeyValueKeys
        self.temporaryItems = temporaryItems
    }

    public func deleteAccount(
        _ request: AccountDeletionRequest,
        closeLocalStores: @escaping @Sendable () async -> Void
    ) async throws {
        let identifier = request.appleUserIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else {
            throw AccountDeletionError.invalidUserIdentifier
        }
        let root: URL
        do {
            root = try rootURLProvider()
        } catch {
            throw AccountDeletionError.storageUnavailable(error.localizedDescription)
        }
        let appleUserHash = JournalAccountScope(
            appleUserIdentifier: identifier,
            storageLocation: request.storageLocation
        ).appleUserHash

        await closeLocalStores()

        let usesICloud: Bool
        if case .iCloud = request.storageLocation {
            usesICloud = true
        } else {
            usesICloud = false
        }
        if usesICloud, let cloudEraser {
            do {
                try await cloudEraser.eraseCloudData(appleUserIdentifier: identifier)
            } catch let error as AccountDeletionError {
                throw error
            } catch {
                throw AccountDeletionError.cloudDeletionFailed(error.localizedDescription)
            }
        }

        let registry = JournalAccountScopeRegistry(root: root)
        let accountDirectory = registry.accountDirectory(appleUserHash: appleUserHash)
        let scopeDirectoryNames = Self.directoryNames(in: accountDirectory)
        var failures: [String] = []
        func remove(_ url: URL) {
            do {
                try Self.removeIfPresent(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        remove(accountDirectory)
        remove(registry.bookkeepingDirectory(appleUserHash: appleUserHash))
        if registry.isLegacyDataClaimed(byAppleUserHash: appleUserHash) {
            for url in Self.legacyStoreItems(root: root) {
                remove(url)
            }
            do {
                try registry.removeLegacyClaim()
            } catch {
                failures.append("legacy-claim.json: \(error.localizedDescription)")
            }
        }
        for url in temporaryItems {
            remove(url)
        }

        var suiteDirectoryNames = Set(scopeDirectoryNames)
        suiteDirectoryNames.insert(JournalStorageLocation.localOnly.directoryName)
        suiteDirectoryNames.insert(request.storageLocation.directoryName)
        for directoryName in suiteDirectoryNames.sorted() {
            preferences.removeSuite(
                named: JournalAccountScope.userDefaultsSuiteName(
                    appleUserHash: appleUserHash,
                    directoryName: directoryName
                )
            )
        }
        if usesICloud, !cloudKeyValueKeys.isEmpty {
            preferences.removeCloudValues(forKeys: cloudKeyValueKeys)
        }

        guard failures.isEmpty else {
            throw AccountDeletionError.localDeletionFailed(failures.joined(separator: ", "))
        }

        do {
            try appLockStore.delete()
            try await sessionService.deleteStoredState()
        } catch {
            throw AccountDeletionError.localDeletionFailed(error.localizedDescription)
        }
        if !standardDefaultsKeys.isEmpty {
            preferences.removeStandardValues(forKeys: standardDefaultsKeys)
        }
    }

    /// The store files the app used before records were split per account.
    /// They sit next to the account-scope root, plus a JSON fallback inside it.
    static func legacyStoreItems(root: URL) -> [URL] {
        let legacyDirectory = root.deletingLastPathComponent()
        let storeNames = ["Canonical.store", "LocalAuxiliary.store"]
        let supportNames = storeNames.map {
            ".\($0.replacingOccurrences(of: ".store", with: ""))_SUPPORT"
        }
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        let storeItems = siblings.filter { url in
            let name = url.lastPathComponent
            return storeNames.contains { name.hasPrefix($0) } || supportNames.contains(name)
        }
        return storeItems + [root.appending(path: "journal-local.json")]
    }

    private static func directoryNames(in directory: URL) -> [String] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
        return contents.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            return isDirectory == true ? url.lastPathComponent : nil
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
