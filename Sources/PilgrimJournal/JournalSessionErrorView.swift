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

struct JournalSessionErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("저장소를 열 수 없습니다")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("다시 시도", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JournalTheme.canvas)
    }
}

struct VisualTestingCloudIdentityChecker: CloudIdentityBindingChecking {
    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        .matched
    }
}

struct OfflineCloudIdentityChecker: CloudIdentityBindingChecking {
    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        .unavailable(reason: String(localized: "이 빌드에는 iCloud 권한이 없어 로컬 모드로 실행합니다."))
    }
}
