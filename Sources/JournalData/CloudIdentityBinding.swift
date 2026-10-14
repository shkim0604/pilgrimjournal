import CloudKit
import CryptoKit
import Foundation

#if os(macOS)
import Security
#endif

public enum CloudKitEntitlement {
    /// `CKContainer(identifier:)` terminates the process when the requested
    /// container is absent from the current code signature. Check the signed
    /// entitlement first so local and ad-hoc builds can safely run offline.
    public static func includes(containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
            ),
            let identifiers = value as? [String]
        else {
            return false
        }
        return identifiers.contains(containerIdentifier)
        #else
        // iOS does not expose SecTask entitlement inspection to applications.
        // Distribution and development builds use the checked-in entitlement.
        return true
        #endif
    }
}

public enum CloudIdentityBindingResult: Equatable, Sendable {
    case matched
    case bound
    case mismatch
    case unavailable(reason: String)
}

public protocol CloudIdentityBindingChecking: Sendable {
    func verifyOrBind(userIdentifier: String) async -> CloudIdentityBindingResult
}

public protocol CloudIdentityBindingStore: Sendable {
    func loadSubjectHash() async throws -> String?
    func saveSubjectHashIfAbsent(_ subjectHash: String) async throws -> String
}

public actor CloudIdentityBindingService: CloudIdentityBindingChecking {
    private let store: any CloudIdentityBindingStore

    public init(store: any CloudIdentityBindingStore) {
        self.store = store
    }

    public func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        let identifier = userIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else {
            return .unavailable(reason: "Apple 로그인 사용자를 확인할 수 없습니다.")
        }

        let subjectHash = Self.subjectHash(for: identifier)
        do {
            if let storedHash = try await store.loadSubjectHash() {
                return storedHash == subjectHash ? .matched : .mismatch
            }
            let storedHash = try await store.saveSubjectHashIfAbsent(subjectHash)
            return storedHash == subjectHash ? .bound : .mismatch
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public static func subjectHash(for userIdentifier: String) -> String {
        let scopedValue = "PilgrimJournal.CloudIdentity.v1:\(userIdentifier)"
        return SHA256.hash(data: Data(scopedValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public actor CloudKitIdentityBindingStore: CloudIdentityBindingStore {
    private static let recordName = "pilgrim-journal-apple-user-binding-v1"
    private static let recordType = "PilgrimJournalAccountBinding"
    private static let subjectHashKey = "appleSubjectHash"

    private let container: CKContainer

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func loadSubjectHash() async throws -> String? {
        try await requireAvailableAccount()
        do {
            let record = try await container.privateCloudDatabase.record(
                for: Self.recordID
            )
            return record[Self.subjectHashKey] as? String
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func saveSubjectHashIfAbsent(
        _ subjectHash: String
    ) async throws -> String {
        try await requireAvailableAccount()
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: Self.recordID
        )
        record[Self.subjectHashKey] = subjectHash as CKRecordValue

        do {
            let saved = try await container.privateCloudDatabase.save(record)
            return (saved[Self.subjectHashKey] as? String) ?? subjectHash
        } catch let error as CKError where error.code == .serverRecordChanged {
            let current = try await container.privateCloudDatabase.record(
                for: Self.recordID
            )
            guard let storedHash = current[Self.subjectHashKey] as? String else {
                throw CloudIdentityBindingStoreError.malformedBinding
            }
            return storedHash
        }
    }

    private static var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName)
    }

    private func requireAvailableAccount() async throws {
        switch try await container.accountStatus() {
        case .available:
            return
        case .noAccount:
            throw CloudIdentityBindingStoreError.unavailable(
                "이 기기에 iCloud 계정이 없습니다."
            )
        case .restricted:
            throw CloudIdentityBindingStoreError.unavailable(
                "이 기기에서 iCloud 사용이 제한되었습니다."
            )
        case .couldNotDetermine, .temporarilyUnavailable:
            throw CloudIdentityBindingStoreError.unavailable(
                "iCloud 계정 상태를 확인할 수 없습니다."
            )
        @unknown default:
            throw CloudIdentityBindingStoreError.unavailable(
                "알 수 없는 iCloud 계정 상태입니다."
            )
        }
    }
}

public enum CloudIdentityBindingStoreError: LocalizedError, Sendable {
    case unavailable(String)
    case malformedBinding

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .malformedBinding:
            "iCloud 사용자 연결 정보를 읽을 수 없습니다."
        }
    }
}
