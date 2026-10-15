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
        let identifier = containerIdentifier
        let status: CKAccountStatus? = await withTaskGroup(
            of: CKAccountStatus??.self
        ) { group in
            group.addTask {
                let container = CKContainer(identifier: identifier)
                return try? await container.accountStatus()
            }
            group.addTask {
                try? await Task.sleep(for: Self.accountStatusTimeout)
                return CKAccountStatus??.none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        guard let status else {
            return .failed(
                message: String(localized: "iCloud 상태 확인이 시간 내에 끝나지 않았습니다.", bundle: .module),
                retryable: true
            )
        }
        switch status {
        case .available:
            return nil
        case .noAccount:
            return .unavailable(reason: String(localized: "iCloud 계정이 없습니다.", bundle: .module))
        case .restricted:
            return .unavailable(
                reason: String(localized: "이 기기에서 iCloud가 제한되었습니다.", bundle: .module))
        case .couldNotDetermine:
            return .unavailable(
                reason: String(localized: "iCloud 계정 상태를 확인할 수 없습니다.", bundle: .module))
        case .temporarilyUnavailable:
            return .failed(
                message: String(localized: "iCloud를 일시적으로 사용할 수 없습니다.", bundle: .module),
                retryable: true)
        @unknown default:
            return .unavailable(
                reason: String(localized: "알 수 없는 iCloud 계정 상태입니다.", bundle: .module))
        }
    }

    /// Seconds to wait for CloudKit before treating the account as unusable.
    ///
    /// `accountStatus()` can hang indefinitely when CloudKit is unhealthy. The
    /// journal session awaits this call before it can build its store, so an
    /// unbounded wait leaves the app stuck on the loading screen with no error.
    static let accountStatusTimeout: Duration = .seconds(10)

    private func accountStatusIsAvailable() async -> Bool {
        let identifier = containerIdentifier
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                let container = CKContainer(identifier: identifier)
                return (try? await container.accountStatus()) == .available
            }
            group.addTask {
                try? await Task.sleep(for: Self.accountStatusTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    public func currentStorageLocation(
        fileManager: FileManager = .default
    ) async -> JournalStorageLocation {
        guard await accountStatusIsAvailable(),
            let token = fileManager.ubiquityIdentityToken,
            let tokenData = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
            )
        else {
            return .localOnly
        }
        return .iCloud(
            accountHash: JournalAccountScope.iCloudAccountHash(
                identityTokenData: tokenData
            )
        )
    }
}
