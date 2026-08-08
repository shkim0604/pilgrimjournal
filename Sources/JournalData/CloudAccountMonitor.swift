import CloudKit
import Foundation
import JournalDomain

public struct CloudAccountMonitor: Sendable {
    private let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    public func currentState() async -> SyncState {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available:
                return .pending
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
}
