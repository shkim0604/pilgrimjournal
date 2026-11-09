import AuthenticationServices
import CloudKit
import Combine
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI

#if PILGRIM_SWIFTDATA
import CoreData
import SwiftData
#endif

#if PILGRIM_SWIFTDATA
func cloudSyncStoreEvent(
    from notification: Notification
) -> CloudSyncStoreEvent? {
    guard
        notification.name
            == NSPersistentCloudKitContainer.eventChangedNotification,
        let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        ] as? NSPersistentCloudKitContainer.Event
    else {
        return nil
    }
    let operation: CloudSyncStoreOperation =
        switch event.type {
        case .setup: .setup
        case .import: .importing
        case .export: .exporting
        @unknown default: .setup
        }
    let errorPresentation = cloudSyncErrorPresentation(for: event.error)
    return CloudSyncStoreEvent(
        operation: operation,
        completedAt: event.endDate,
        succeeded: event.succeeded,
        errorDescription: errorPresentation?.message,
        errorRetryable: errorPresentation?.retryable
    )
}

struct CloudSyncErrorPresentation: Equatable {
    var message: String
    var retryable: Bool
}

func cloudSyncErrorPresentation(
    for error: Error?
) -> CloudSyncErrorPresentation? {
    guard let error else { return nil }
    let errors = flattenedCloudErrors(error as NSError)

    if errors.contains(where: {
        cloudDiagnosticText($0).localizedCaseInsensitiveContains(
            "cannot create new type"
        )
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "CloudKit 프로덕션 스키마가 아직 배포되지 않았습니다."),
            retryable: false
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.notAuthenticated.rawValue
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "iCloud에 로그인한 뒤 동기화를 다시 시도하세요."),
            retryable: true
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.quotaExceeded.rawValue
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "iCloud 저장 공간이 부족해 동기화할 수 없습니다."),
            retryable: false
        )
    }
    if errors.contains(where: {
        guard $0.domain == CKErrorDomain else { return false }
        return [
            CKError.networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
        ].map(\.rawValue).contains($0.code)
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "네트워크 또는 CloudKit 서비스가 일시적으로 불안정합니다."),
            retryable: true
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.partialFailure.rawValue
    }) {
        let detail = errors.dropFirst().first.map { cloudDiagnosticText($0) }
        return CloudSyncErrorPresentation(
            message: detail.map { String(localized: "일부 기록 동기화에 실패했습니다: \($0)") }
                ?? String(localized: "일부 기록 동기화에 실패했습니다."),
            retryable: true
        )
    }
    return CloudSyncErrorPresentation(
        message: error.localizedDescription,
        retryable: true
    )
}

private func flattenedCloudErrors(
    _ error: NSError,
    depth: Int = 0
) -> [NSError] {
    guard depth < 8 else { return [error] }
    var result = [error]
    if let partial = error.userInfo[CKPartialErrorsByItemIDKey]
        as? [AnyHashable: NSError]
    {
        for nested in partial.values {
            result.append(contentsOf: flattenedCloudErrors(nested, depth: depth + 1))
        }
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        result.append(contentsOf: flattenedCloudErrors(underlying, depth: depth + 1))
    }
    return result
}

private func cloudDiagnosticText(_ error: NSError) -> String {
    [
        error.localizedDescription,
        error.localizedFailureReason,
        error.userInfo[NSDebugDescriptionErrorKey] as? String,
        error.userInfo["CKErrorDescription"] as? String,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
}
#endif
