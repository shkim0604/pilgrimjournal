import Foundation
import JournalDomain

public enum JournalStorageLocation: Codable, Equatable, Sendable {
    case localOnly
    case iCloud(accountHash: String)

    public var directoryName: String {
        switch self {
        case .localOnly:
            "local-only"
        case let .iCloud(accountHash):
            "icloud-\(accountHash)"
        }
    }
}

public struct JournalAccountScope: Codable, Equatable, Sendable {
    public var appleUserHash: String
    public var storageLocation: JournalStorageLocation

    public init(
        appleUserHash: String,
        storageLocation: JournalStorageLocation
    ) {
        self.appleUserHash = appleUserHash
        self.storageLocation = storageLocation
    }

    public init(
        appleUserIdentifier: String,
        storageLocation: JournalStorageLocation
    ) {
        appleUserHash = ContentHash.sha256Hex(
            "PilgrimJournal.AppleUser.v1\u{1F}\(appleUserIdentifier)"
        )
        self.storageLocation = storageLocation
    }

    public var relativeDirectory: String {
        "Accounts/\(appleUserHash)/\(storageLocation.directoryName)"
    }

    /// The UserDefaults suite that keeps this scope's notebook and kind
    /// catalog preferences.
    public var userDefaultsSuiteName: String {
        Self.userDefaultsSuiteName(
            appleUserHash: appleUserHash,
            directoryName: storageLocation.directoryName
        )
    }

    public static func userDefaultsSuiteName(
        appleUserHash: String,
        directoryName: String
    ) -> String {
        "PilgrimJournal.\(appleUserHash).\(directoryName)"
    }

    public static func iCloudAccountHash(identityTokenData: Data) -> String {
        ContentHash.sha256Hex(
            "PilgrimJournal.iCloudAccount.v1\u{1F}"
                + identityTokenData.base64EncodedString()
        )
    }
}

public enum JournalAccountScopeError: LocalizedError, Equatable, Sendable {
    case legacyDataClaimedByDifferentUser
    case invalidScopeManifest
    case unavailableICloudIdentity

    public var errorDescription: String? {
        switch self {
        case .legacyDataClaimedByDifferentUser:
            String(localized: "기존 로컬 데이터는 다른 Apple 로그인 사용자에게 귀속되어 있습니다.", bundle: .module)
        case .invalidScopeManifest:
            String(localized: "계정별 저장소 정보를 확인할 수 없습니다.", bundle: .module)
        case .unavailableICloudIdentity:
            String(localized: "시스템 iCloud 계정을 안전하게 식별할 수 없어 로컬 전용 저장소를 사용합니다.", bundle: .module)
        }
    }
}

/// Whether an iCloud scope's (Apple user, iCloud account) pair passed the
/// cloud identity check on this device.
public enum CloudIdentityVerification: Equatable, Sendable {
    /// `.matched` or `.bound` was recorded for this pair.
    case verified
    /// The scope already existed when this device started recording checks.
    /// Trusted only while a check cannot run, so returning users keep their
    /// journal offline; a `.mismatch` clears it.
    case carriedOver
    case unverified
}

public struct JournalAccountScopeRegistry: Sendable {
    private struct CloudIdentityRecord: Codable, Equatable {
        var version = 1
        var verified: Set<String> = []
        var carriedOver: Set<String> = []
    }

    private struct LegacyClaim: Codable, Equatable {
        var version = 1
        var appleUserHash: String
        var claimedAt: Date
    }

    private struct ScopeManifest: Codable, Equatable {
        var version = 1
        var scope: JournalAccountScope
        var createdAt: Date
    }

    private struct MigrationReceipt: Codable, Equatable {
        var version = 1
        var source: JournalAccountScope
        var destination: JournalAccountScope
        var completedAt: Date
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func verifyLegacyClaim(for scope: JournalAccountScope) throws {
        guard FileManager.default.fileExists(atPath: legacyClaimURL.path) else { return }
        let claim = try decode(LegacyClaim.self, at: legacyClaimURL)
        guard claim.appleUserHash == scope.appleUserHash else {
            throw JournalAccountScopeError.legacyDataClaimedByDifferentUser
        }
    }

    public func claimLegacyData(
        for scope: JournalAccountScope,
        at date: Date = .now
    ) throws {
        try verifyLegacyClaim(for: scope)
        guard !FileManager.default.fileExists(atPath: legacyClaimURL.path) else { return }
        try writeAtomically(
            LegacyClaim(appleUserHash: scope.appleUserHash, claimedAt: date),
            to: legacyClaimURL
        )
    }

    public func prepareScope(
        _ scope: JournalAccountScope,
        at date: Date = .now
    ) throws -> JournalPaths {
        let paths = JournalPaths(
            root: root.appending(path: scope.relativeDirectory, directoryHint: .isDirectory)
        )
        try paths.prepare()
        let manifestURL = paths.root.appending(path: "scope.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try decode(ScopeManifest.self, at: manifestURL)
            guard manifest.scope == scope else {
                throw JournalAccountScopeError.invalidScopeManifest
            }
        } else {
            try writeAtomically(
                ScopeManifest(scope: scope, createdAt: date),
                to: manifestURL
            )
        }
        return paths
    }

    public func hasPreparedScope(_ scope: JournalAccountScope) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appending(
                path: scope.relativeDirectory + "/scope.json"
            ).path)
    }

    public func shouldMigrateLegacyData(
        for scope: JournalAccountScope
    ) throws -> Bool {
        try verifyLegacyClaim(for: scope)
        return !FileManager.default.fileExists(atPath: legacyClaimURL.path)
    }

    public func hasCompletedMigration(
        from source: JournalAccountScope,
        to destination: JournalAccountScope
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: migrationReceiptURL(
                from: source,
                to: destination
            ).path)
    }

    public func markMigrationCompleted(
        from source: JournalAccountScope,
        to destination: JournalAccountScope,
        at date: Date = .now
    ) throws {
        try writeAtomically(
            MigrationReceipt(
                source: source,
                destination: destination,
                completedAt: date
            ),
            to: migrationReceiptURL(from: source, to: destination)
        )
    }

    /// Every scope one Apple user has on this device: `Accounts/<hash>/`.
    public func accountDirectory(appleUserHash: String) -> URL {
        root.appending(path: "Accounts/\(appleUserHash)", directoryHint: .isDirectory)
    }

    /// Migration receipts and the cloud identity record kept for one Apple
    /// user: `AccountScopes/<hash>/`.
    public func bookkeepingDirectory(appleUserHash: String) -> URL {
        root.appending(path: "AccountScopes/\(appleUserHash)", directoryHint: .isDirectory)
    }

    /// Whether the pre-account-scope store was claimed by this Apple user.
    /// An unreadable claim counts as someone else's, so it is never removed.
    public func isLegacyDataClaimed(byAppleUserHash appleUserHash: String) -> Bool {
        guard FileManager.default.fileExists(atPath: legacyClaimURL.path),
            let claim = try? decode(LegacyClaim.self, at: legacyClaimURL)
        else {
            return false
        }
        return claim.appleUserHash == appleUserHash
    }

    /// Forgets who claimed the legacy store, so the next Apple user to sign in
    /// is not refused as a different owner.
    public func removeLegacyClaim() throws {
        guard FileManager.default.fileExists(atPath: legacyClaimURL.path) else { return }
        try FileManager.default.removeItem(at: legacyClaimURL)
    }

    public func cloudIdentityVerification(
        for scope: JournalAccountScope
    ) throws -> CloudIdentityVerification {
        let record = try cloudIdentityRecord(appleUserHash: scope.appleUserHash)
        let name = scope.storageLocation.directoryName
        if record.verified.contains(name) { return .verified }
        if record.carriedOver.contains(name) { return .carriedOver }
        return .unverified
    }

    /// Records a `.matched`/`.bound` check. Returns whether it was new.
    @discardableResult
    public func markCloudIdentityVerified(_ scope: JournalAccountScope) throws -> Bool {
        var record = try cloudIdentityRecord(appleUserHash: scope.appleUserHash)
        guard record.verified.insert(scope.storageLocation.directoryName).inserted else {
            return false
        }
        try writeAtomically(record, to: cloudIdentityURL(appleUserHash: scope.appleUserHash))
        return true
    }

    /// Forgets every verified and carried-over pair of this Apple user. The
    /// emptied record stays, so the one-time carry-over never runs again.
    public func clearCloudIdentityVerification(appleUserHash: String) throws {
        try writeAtomically(
            CloudIdentityRecord(),
            to: cloudIdentityURL(appleUserHash: appleUserHash)
        )
    }

    /// Loads the record, creating it on first use. Builds before this record
    /// existed opened the iCloud scope on any saved sign-in, so the scopes
    /// already on disk then are carried over. New scopes are only prepared
    /// after a check, which reads (and so creates) the record first.
    private func cloudIdentityRecord(appleUserHash: String) throws -> CloudIdentityRecord {
        let url = cloudIdentityURL(appleUserHash: appleUserHash)
        if FileManager.default.fileExists(atPath: url.path) {
            return try decode(CloudIdentityRecord.self, at: url)
        }
        let accountDirectory = accountDirectory(appleUserHash: appleUserHash)
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: accountDirectory.path)) ?? []
        let record = CloudIdentityRecord(
            carriedOver: Set(
                names.filter {
                    $0.hasPrefix("icloud-")
                        && FileManager.default.fileExists(
                            atPath: accountDirectory.appending(path: "\($0)/scope.json").path)
                })
        )
        try writeAtomically(record, to: url)
        return record
    }

    private func cloudIdentityURL(appleUserHash: String) -> URL {
        bookkeepingDirectory(appleUserHash: appleUserHash).appending(path: "cloud-identity.json")
    }

    private var legacyClaimURL: URL {
        root.appending(path: "AccountScopes/legacy-claim.json")
    }

    private func migrationReceiptURL(
        from source: JournalAccountScope,
        to destination: JournalAccountScope
    ) -> URL {
        let sourceKey = source.storageLocation.directoryName
        let destinationKey = destination.storageLocation.directoryName
        return root.appending(
            path: "AccountScopes/\(source.appleUserHash)/\(sourceKey)-to-\(destinationKey).json"
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw JournalAccountScopeError.invalidScopeManifest
        }
    }

    private func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
    }
}
