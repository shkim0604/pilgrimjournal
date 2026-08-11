import CloudKit
import Foundation
import JournalDomain

public struct CloudAccountMonitor: Sendable {
    private let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    /// Reports an iCloud account problem, or `nil` when the account is usable.
    ///
    /// A usable account says nothing about whether a sync is in flight, so it
    /// deliberately reports nothing. Treating it as a pending sync would
    /// overwrite the state the CloudKit events established and leave the UI
    /// waiting for an event that never arrives.
    public func currentProblem() async -> SyncState? {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available:
                return nil
            case .noAccount:
                return .unavailable(reason: "iCloud 계정이 없습니다.")
            case .restricted:
                return .unavailable(reason: "이 기기에서 iCloud가 제한되었습니다.")
            case .couldNotDetermine:
                return .unavailable(reason: "iCloud 계정 상태를 확인할 수 없습니다.")
            case .temporarilyUnavailable:
                return .failed(message: "iCloud를 일시적으로 사용할 수 없습니다.", retryable: true)
            @unknown default:
                return .unavailable(reason: "알 수 없는 iCloud 계정 상태입니다.")
            }
        } catch {
            return .failed(message: error.localizedDescription, retryable: true)
        }
    }

    public func currentStorageLocation(
        fileManager: FileManager = .default
    ) async -> JournalStorageLocation {
        let container = CKContainer(identifier: containerIdentifier)
        guard (try? await container.accountStatus()) == .available,
              let token = fileManager.ubiquityIdentityToken,
              let tokenData = try? NSKeyedArchiver.archivedData(
                  withRootObject: token,
                  requiringSecureCoding: true
              ) else {
            return .localOnly
        }
        return .iCloud(
            accountHash: JournalAccountScope.iCloudAccountHash(
                identityTokenData: tokenData
            )
        )
    }
}
